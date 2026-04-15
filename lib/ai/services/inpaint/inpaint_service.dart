import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:onnxruntime_v2/onnxruntime_v2.dart' as ort;

import '../../../core/logging/app_logger.dart';
import '../../inference/image_tensor.dart';
import '../../runtime/ort_runtime.dart';
import '../bg_removal/image_io.dart';

final _log = AppLogger('InpaintService');

/// LaMa inpainting service backed by an ONNX model.
///
/// LaMa takes two inputs:
///   'image': `[1, 3, 512, 512]` float32 in `[0, 1]`
///   'mask':  `[1, 1, 512, 512]` float32 in `{0, 1}` (1 = inpaint)
///
/// Output: `[1, 3, 512, 512]` float32 inpainted image in `[0, 1]`
///
/// The mask comes from the draw tool — white pixels mark the area to
/// inpaint. After inference, only the masked pixels are composited
/// back onto the original to preserve unmasked detail.
///
/// Ownership of the [OrtV2Session] transfers to this service — [close]
/// releases it.
class InpaintService {
  InpaintService({required this.session});

  /// LaMa's native input/output size.
  static const int inputSize = 512;

  final OrtV2Session session;
  bool _closed = false;

  /// Inpaint the image at [sourcePath] using the given [maskRgba].
  ///
  /// [maskRgba] is an RGBA buffer of size [maskWidth] x [maskHeight]
  /// where white (R >= 128) pixels mark the region to inpaint.
  ///
  /// Returns a `ui.Image` with inpainted regions blended back into the
  /// original.
  Future<ui.Image> inpaintFromPath(
    String sourcePath, {
    required Uint8List maskRgba,
    required int maskWidth,
    required int maskHeight,
  }) async {
    if (_closed) {
      _log.w('run rejected — session closed', {'path': sourcePath});
      throw const InpaintException('InpaintService is closed');
    }
    final total = Stopwatch()..start();
    _log.i('run start', {
      'path': sourcePath,
      'maskW': maskWidth,
      'maskH': maskHeight,
      'inputs': session.inputNames,
      'outputs': session.outputNames,
    });
    ort.OrtValue? imageInput;
    ort.OrtValue? maskInput;
    List<ort.OrtValue?>? outputs;
    try {
      // 1. Decode source image into raw RGBA, capped at 512 px.
      final decoded = await BgRemovalImageIo.decodeFileToRgba(
        sourcePath,
        maxDimension: inputSize,
      );
      _log.d('source decoded', {
        'path': sourcePath,
        'w': decoded.width,
        'h': decoded.height,
      });

      // 2. Build the image tensor [1,3,512,512] in [0,1] range.
      final preSw = Stopwatch()..start();
      final imageTensor = ImageTensor.fromRgba(
        rgba: decoded.bytes,
        srcWidth: decoded.width,
        srcHeight: decoded.height,
        dstWidth: inputSize,
        dstHeight: inputSize,
      );

      // 3. Build the mask tensor [1,1,512,512]. Extract the R channel
      //    from the RGBA mask, threshold at 128, bilinear resize to
      //    512x512, and normalize to {0, 1}.
      final maskTensor = _buildMaskTensor(
        maskRgba: maskRgba,
        maskWidth: maskWidth,
        maskHeight: maskHeight,
        dstSize: inputSize,
      );
      preSw.stop();
      _log.d('preprocessed', {'ms': preSw.elapsedMilliseconds});

      // 4. Wrap tensors as OrtValues.
      imageInput = ort.OrtValueTensor.createTensorWithDataList(
        imageTensor.data,
        imageTensor.shape,
      );
      maskInput = ort.OrtValueTensor.createTensorWithDataList(
        maskTensor,
        [1, 1, inputSize, inputSize],
      );

      // 5. Map input names. LaMa expects 'image' and 'mask' but we
      //    check the session metadata to handle name variations.
      final inputMap = _mapInputs(
        imageValue: imageInput,
        maskValue: maskInput,
      );

      // 6. Run inference.
      final inferSw = Stopwatch()..start();
      outputs = await session.runTyped(inputMap);
      inferSw.stop();
      _log.d('inference', {'ms': inferSw.elapsedMilliseconds});

      if (outputs.isEmpty || outputs.first == null) {
        throw const InpaintException('LaMa returned no output tensor');
      }

      // 7. Extract the float output [1,3,512,512].
      final raw = outputs.first!.value;
      final inpaintedChw = _flattenChw(raw);
      if (inpaintedChw == null) {
        throw const InpaintException('LaMa output shape unrecognized');
      }

      // 8. Build the composite: blend inpainted pixels into the
      //    original where mask=1, keep original elsewhere.
      final postSw = Stopwatch()..start();
      final compositedRgba = _compositeInpainted(
        originalRgba: decoded.bytes,
        originalWidth: decoded.width,
        originalHeight: decoded.height,
        inpaintedChw: inpaintedChw,
        inpaintedSize: inputSize,
        maskRgba: maskRgba,
        maskWidth: maskWidth,
        maskHeight: maskHeight,
      );
      postSw.stop();
      _log.d('postprocessed', {'ms': postSw.elapsedMilliseconds});

      // 9. Re-upload as a ui.Image at the original decoded dimensions.
      final image = await BgRemovalImageIo.encodeRgbaToUiImage(
        rgba: compositedRgba,
        width: decoded.width,
        height: decoded.height,
      );
      total.stop();
      _log.i('run complete', {
        'totalMs': total.elapsedMilliseconds,
        'preMs': preSw.elapsedMilliseconds,
        'inferMs': inferSw.elapsedMilliseconds,
        'postMs': postSw.elapsedMilliseconds,
        'outputW': image.width,
        'outputH': image.height,
      });
      return image;
    } on InpaintException {
      rethrow;
    } on BgRemovalIoException catch (e) {
      total.stop();
      _log.w('run IO failure — rewrapping', {
        'message': e.message,
        'ms': total.elapsedMilliseconds,
      });
      throw InpaintException(e.message, cause: e);
    } catch (e, st) {
      total.stop();
      _log.e('run failed',
          error: e, stackTrace: st, data: {'ms': total.elapsedMilliseconds});
      throw InpaintException(e.toString(), cause: e);
    } finally {
      try {
        imageInput?.release();
      } catch (e) {
        _log.w('image input release failed', {'error': e.toString()});
      }
      try {
        maskInput?.release();
      } catch (e) {
        _log.w('mask input release failed', {'error': e.toString()});
      }
      if (outputs != null) {
        for (final o in outputs) {
          try {
            o?.release();
          } catch (e) {
            _log.w('output release failed', {'error': e.toString()});
          }
        }
      }
    }
  }

  /// Build a [1,1,dstSize,dstSize] mask tensor from RGBA mask pixels.
  ///
  /// Extracts the R channel, thresholds at 128, bilinear-resizes to
  /// [dstSize] x [dstSize], and normalizes to {0.0, 1.0}.
  static Float32List _buildMaskTensor({
    required Uint8List maskRgba,
    required int maskWidth,
    required int maskHeight,
    required int dstSize,
  }) {
    final hw = dstSize * dstSize;
    final out = Float32List(hw);

    final yDen = dstSize > 1 ? (dstSize - 1) : 1;
    final xDen = dstSize > 1 ? (dstSize - 1) : 1;
    final yScale = (maskHeight - 1) / yDen;
    final xScale = (maskWidth - 1) / xDen;

    for (int y = 0; y < dstSize; y++) {
      final sy = y * yScale;
      final y0 = sy.floor().clamp(0, maskHeight - 1);
      for (int x = 0; x < dstSize; x++) {
        final sx = x * xScale;
        final x0 = sx.floor().clamp(0, maskWidth - 1);
        // Sample the R channel of the nearest pixel.
        final idx = (y0 * maskWidth + x0) * 4;
        out[y * dstSize + x] = maskRgba[idx] >= 128 ? 1.0 : 0.0;
      }
    }
    return out;
  }

  /// Map session input names to the image and mask OrtValues.
  ///
  /// LaMa typically names inputs 'image' and 'mask', but we check the
  /// actual session metadata to handle model variations.
  Map<String, ort.OrtValue> _mapInputs({
    required ort.OrtValue imageValue,
    required ort.OrtValue maskValue,
  }) {
    final names = session.inputNames;
    if (names.length < 2) {
      throw InpaintException(
        'LaMa model has ${names.length} inputs, expected 2 (image + mask)',
      );
    }

    // Try to match by name; fall back to positional order.
    String imageName = names[0];
    String maskName = names[1];
    for (final name in names) {
      final lower = name.toLowerCase();
      if (lower.contains('image') || lower.contains('input')) {
        imageName = name;
      } else if (lower.contains('mask')) {
        maskName = name;
      }
    }

    _log.d('input mapping', {
      'imageName': imageName,
      'maskName': maskName,
      'allNames': names,
    });
    return {imageName: imageValue, maskName: maskValue};
  }

  /// Walk a nested `[1][3][H][W]` tensor into a flat [Float32List].
  /// Returns null if the shape doesn't match.
  static Float32List? _flattenChw(Object? raw) {
    if (raw is! List || raw.isEmpty) return null;
    // Drop batch dimension.
    List current = raw;
    if (current.first is List &&
        (current.first as List).isNotEmpty &&
        (current.first as List).first is List) {
      current = current.first as List;
    }
    if (current.length != 3) return null;
    final c0 = current[0];
    if (c0 is! List || c0.isEmpty) return null;
    final height = c0.length;
    if (c0.first is! List) return null;
    final width = (c0.first as List).length;
    if (width == 0) return null;

    final out = Float32List(3 * height * width);
    for (int c = 0; c < 3; c++) {
      final plane = current[c];
      if (plane is! List || plane.length != height) return null;
      for (int y = 0; y < height; y++) {
        final row = plane[y];
        if (row is! List || row.length != width) return null;
        for (int x = 0; x < width; x++) {
          final v = row[x];
          if (v is num) {
            out[c * height * width + y * width + x] = v.toDouble();
          } else {
            return null;
          }
        }
      }
    }
    return out;
  }

  /// Composite inpainted CHW pixels back into the original RGBA where
  /// the mask is active (R >= 128). Unmasked pixels keep original
  /// values.
  static Uint8List _compositeInpainted({
    required Uint8List originalRgba,
    required int originalWidth,
    required int originalHeight,
    required Float32List inpaintedChw,
    required int inpaintedSize,
    required Uint8List maskRgba,
    required int maskWidth,
    required int maskHeight,
  }) {
    final out = Uint8List.fromList(originalRgba);
    final hw = inpaintedSize * inpaintedSize;

    for (int y = 0; y < originalHeight; y++) {
      for (int x = 0; x < originalWidth; x++) {
        // Sample the mask at the original image's coordinate.
        final maskX =
            (x * (maskWidth - 1) / (originalWidth - 1).clamp(1, originalWidth))
                .round()
                .clamp(0, maskWidth - 1);
        final maskY = (y *
                (maskHeight - 1) /
                (originalHeight - 1).clamp(1, originalHeight))
            .round()
            .clamp(0, maskHeight - 1);
        final maskIdx = (maskY * maskWidth + maskX) * 4;

        if (maskRgba[maskIdx] >= 128) {
          // This pixel is in the inpaint region — sample from the
          // inpainted output (which is at inpaintedSize x inpaintedSize).
          final inpX = (x * (inpaintedSize - 1) / (originalWidth - 1).clamp(1, originalWidth))
              .round()
              .clamp(0, inpaintedSize - 1);
          final inpY = (y * (inpaintedSize - 1) / (originalHeight - 1).clamp(1, originalHeight))
              .round()
              .clamp(0, inpaintedSize - 1);
          final inpIdx = inpY * inpaintedSize + inpX;

          final outIdx = (y * originalWidth + x) * 4;
          out[outIdx] =
              (inpaintedChw[inpIdx].clamp(0.0, 1.0) * 255).round();
          out[outIdx + 1] =
              (inpaintedChw[hw + inpIdx].clamp(0.0, 1.0) * 255).round();
          out[outIdx + 2] =
              (inpaintedChw[hw * 2 + inpIdx].clamp(0.0, 1.0) * 255).round();
          // Keep original alpha.
        }
      }
    }
    return out;
  }

  /// Release the underlying session.
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _log.i('close');
    await session.close();
  }
}

/// Typed exception for inpainting failures.
class InpaintException implements Exception {
  const InpaintException(this.message, {this.cause});
  final String message;
  final Object? cause;

  @override
  String toString() {
    if (cause == null) return 'InpaintException: $message';
    return 'InpaintException: $message (caused by $cause)';
  }
}
