import 'dart:typed_data';
import 'dart:ui' as ui;

import '../../../core/logging/app_logger.dart';
import '../../runtime/litert_runtime.dart';
import '../bg_removal/image_io.dart';

final _log = AppLogger('StyleTransferService');

/// Magenta arbitrary style transfer service backed by a TFLite model.
///
/// The transfer model takes two inputs:
///   0: content image `[1, 384, 384, 3]` float32 in `[0, 1]` (HWC)
///   1: style bottleneck vector `[1, 100]` float32
///
/// Output: `[1, 384, 384, 3]` float32 styled image in `[0, 1]` (HWC)
///
/// NOTE: Magenta uses HWC (height-width-channel) layout, not the CHW
/// layout used by PyTorch models like RMBG.
///
/// Ownership of the [LiteRtSession] transfers to this service — [close]
/// releases it.
class StyleTransferService {
  StyleTransferService({required this.session});

  /// Magenta's native input/output spatial resolution.
  /// The int8 transfer model from TFHub uses 384×384.
  static const int inputSize = 384;

  /// Length of the style bottleneck vector.
  static const int styleVectorLength = 100;

  final LiteRtSession session;
  bool _closed = false;

  /// Apply the given [styleVector] to the image at [sourcePath].
  ///
  /// The [styleVector] is a `Float32List` of length 100 — the
  /// bottleneck output from the Magenta prediction model. For this
  /// service we receive pre-computed vectors from [StylePresets].
  ///
  /// Returns a `ui.Image` at 384×384 with the style applied.
  Future<ui.Image> transferFromPath(
    String sourcePath, {
    required Float32List styleVector,
  }) async {
    if (_closed) {
      _log.w('run rejected — session closed', {'path': sourcePath});
      throw const StyleTransferException('StyleTransferService is closed');
    }
    if (styleVector.length != styleVectorLength) {
      throw StyleTransferException(
        'styleVector length ${styleVector.length} does not match '
        'expected $styleVectorLength',
      );
    }
    final total = Stopwatch()..start();
    _log.i('run start', {'path': sourcePath});

    try {
      // 1. Decode source image into raw RGBA, capped at inputSize (384) px.
      final decoded = await BgRemovalImageIo.decodeFileToRgba(
        sourcePath,
        maxDimension: inputSize,
      );
      _log.d('source decoded', {
        'path': sourcePath,
        'w': decoded.width,
        'h': decoded.height,
      });

      // 2. Build the content tensor [1,384,384,3] in HWC layout, [0,1].
      final preSw = Stopwatch()..start();
      final contentTensor = _buildHwcTensor(
        rgba: decoded.bytes,
        srcWidth: decoded.width,
        srcHeight: decoded.height,
        dstWidth: inputSize,
        dstHeight: inputSize,
      );
      preSw.stop();
      _log.d('preprocessed', {'ms': preSw.elapsedMilliseconds});

      // 3. Wrap the style vector as [1,1,1,100] nested list.
      // Magenta's transfer model expects a 4D tensor for the style
      // bottleneck: [batch, 1, 1, style_dims].
      final styleInput = [
        [
          [styleVector.toList()]
        ]
      ];

      // 4. Prepare output buffer [1,384,384,3] in HWC layout.
      final outputBuffer = List.generate(
        1,
        (_) => List.generate(
          inputSize,
          (_) => List.generate(
            inputSize,
            (_) => List<double>.filled(3, 0.0),
          ),
        ),
      );

      // 5. Run inference on the isolate interpreter.
      final inferSw = Stopwatch()..start();
      await session.runTyped(
        [contentTensor, styleInput],
        {0: outputBuffer},
      );
      inferSw.stop();
      _log.d('inference', {'ms': inferSw.elapsedMilliseconds});

      // 6. Convert [1,384,384,3] HWC output back to RGBA pixels.
      final postSw = Stopwatch()..start();
      final rgba = _hwcToRgba(outputBuffer[0], inputSize, inputSize);
      postSw.stop();
      _log.d('postprocessed', {'ms': postSw.elapsedMilliseconds});

      // 7. Re-upload as a ui.Image.
      final image = await BgRemovalImageIo.encodeRgbaToUiImage(
        rgba: rgba,
        width: inputSize,
        height: inputSize,
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
    } on StyleTransferException {
      rethrow;
    } on BgRemovalIoException catch (e) {
      total.stop();
      _log.w('run IO failure — rewrapping', {
        'message': e.message,
        'ms': total.elapsedMilliseconds,
      });
      throw StyleTransferException(e.message, cause: e);
    } catch (e, st) {
      total.stop();
      _log.e('run failed',
          error: e, stackTrace: st, data: {'ms': total.elapsedMilliseconds});
      throw StyleTransferException(e.toString(), cause: e);
    }
  }

  /// Build a `[1][H][W][3]` HWC tensor from RGBA pixels with bilinear
  /// resize and [0,1] normalization. Magenta models use HWC layout
  /// (unlike the CHW layout in [ImageTensor]).
  static List<List<List<List<double>>>> _buildHwcTensor({
    required Uint8List rgba,
    required int srcWidth,
    required int srcHeight,
    required int dstWidth,
    required int dstHeight,
  }) {
    final yDen = dstHeight > 1 ? (dstHeight - 1) : 1;
    final xDen = dstWidth > 1 ? (dstWidth - 1) : 1;
    final yScale = (srcHeight - 1) / yDen;
    final xScale = (srcWidth - 1) / xDen;

    final out = List.generate(
      1,
      (_) => List.generate(
        dstHeight,
        (y) {
          final sy = y * yScale;
          final y0 = sy.floor().clamp(0, srcHeight - 1);
          final y1 = (y0 + 1).clamp(0, srcHeight - 1);
          final wy = sy - y0;

          return List.generate(dstWidth, (x) {
            final sx = x * xScale;
            final x0 = sx.floor().clamp(0, srcWidth - 1);
            final x1 = (x0 + 1).clamp(0, srcWidth - 1);
            final wx = sx - x0;

            final i00 = (y0 * srcWidth + x0) * 4;
            final i01 = (y0 * srcWidth + x1) * 4;
            final i10 = (y1 * srcWidth + x0) * 4;
            final i11 = (y1 * srcWidth + x1) * 4;

            final r =
                ((rgba[i00] * (1 - wx) + rgba[i01] * wx) * (1 - wy) +
                        (rgba[i10] * (1 - wx) + rgba[i11] * wx) * wy) /
                    255.0;
            final g =
                ((rgba[i00 + 1] * (1 - wx) + rgba[i01 + 1] * wx) * (1 - wy) +
                        (rgba[i10 + 1] * (1 - wx) + rgba[i11 + 1] * wx) *
                            wy) /
                    255.0;
            final b =
                ((rgba[i00 + 2] * (1 - wx) + rgba[i01 + 2] * wx) * (1 - wy) +
                        (rgba[i10 + 2] * (1 - wx) + rgba[i11 + 2] * wx) *
                            wy) /
                    255.0;

            return [r, g, b];
          });
        },
      ),
    );
    return out;
  }

  /// Convert a `[H][W][3]` HWC nested list (float [0,1]) to a flat
  /// RGBA `Uint8List`.
  static Uint8List _hwcToRgba(
    List<List<List<double>>> hwc,
    int width,
    int height,
  ) {
    final rgba = Uint8List(width * height * 4);
    for (int y = 0; y < height; y++) {
      for (int x = 0; x < width; x++) {
        final pixel = hwc[y][x];
        final idx = (y * width + x) * 4;
        rgba[idx] = (pixel[0].clamp(0.0, 1.0) * 255).round();
        rgba[idx + 1] = (pixel[1].clamp(0.0, 1.0) * 255).round();
        rgba[idx + 2] = (pixel[2].clamp(0.0, 1.0) * 255).round();
        rgba[idx + 3] = 255; // fully opaque
      }
    }
    return rgba;
  }

  /// Release the underlying session.
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _log.i('close');
    await session.close();
  }
}

/// Typed exception for style transfer failures.
class StyleTransferException implements Exception {
  const StyleTransferException(this.message, {this.cause});
  final String message;
  final Object? cause;

  @override
  String toString() {
    if (cause == null) return 'StyleTransferException: $message';
    return 'StyleTransferException: $message (caused by $cause)';
  }
}
