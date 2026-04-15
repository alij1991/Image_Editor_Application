import 'dart:typed_data';
import 'dart:ui' as ui;

import '../../../core/logging/app_logger.dart';
import '../../runtime/litert_runtime.dart';
import '../bg_removal/image_io.dart';

final _log = AppLogger('SuperResService');

/// Real-ESRGAN 4x super-resolution service backed by a TFLite model.
///
/// Input:  `[1, H, W, 3]` float32 in `[0, 1]` (HWC layout)
/// Output: `[1, H*4, W*4, 3]` float32 in `[0, 1]` (HWC layout)
///
/// The source image is capped at 128 px on the longest edge to keep
/// memory reasonable — the 4x output is 512 px.
class SuperResService {
  SuperResService({required this.session});

  /// Model input size. Source images are downscaled to fit this.
  /// 256px input → 1024px output gives reasonable quality vs memory.
  static const int inputSize = 256;

  /// Model output size (4x the input).
  static const int outputSize = 1024;

  final LiteRtSession session;
  bool _closed = false;

  Future<ui.Image> enhanceFromPath(String sourcePath) async {
    if (_closed) {
      _log.w('run rejected — session closed', {'path': sourcePath});
      throw const SuperResException('SuperResService is closed');
    }
    final total = Stopwatch()..start();
    _log.i('run start', {'path': sourcePath});

    try {
      // 1. Decode source image into raw RGBA, capped at inputSize px.
      final decoded = await BgRemovalImageIo.decodeFileToRgba(
        sourcePath,
        maxDimension: inputSize,
      );
      final srcW = decoded.width;
      final srcH = decoded.height;
      _log.d('source decoded', {'path': sourcePath, 'w': srcW, 'h': srcH});

      // 2. Build HWC tensor [1, inputSize, inputSize, 3] in [0,1].
      //    The source is letterboxed (centered with black padding) to
      //    preserve aspect ratio instead of stretching.
      final preSw = Stopwatch()..start();
      final contentTensor = _buildLetterboxedHwcTensor(
        rgba: decoded.bytes,
        srcWidth: srcW,
        srcHeight: srcH,
        dstSize: inputSize,
      );
      preSw.stop();
      _log.d('preprocessed', {'ms': preSw.elapsedMilliseconds});

      // 3. Prepare output buffer [3, outputSize, outputSize] CHW (no batch).
      final outputBuffer = List.generate(
        3,
        (_) => List.generate(
          outputSize,
          (_) => List<double>.filled(outputSize, 0.0),
        ),
      );

      // 4. Run inference.
      final inferSw = Stopwatch()..start();
      await session.runTyped(
        [contentTensor],
        {0: outputBuffer},
      );
      inferSw.stop();
      _log.d('inference', {'ms': inferSw.elapsedMilliseconds});

      // 5. Convert CHW output to RGBA and crop the letterboxed
      //    padding to recover the original aspect ratio at 4× scale.
      final postSw = Stopwatch()..start();
      final scale = inputSize / (srcW > srcH ? srcW : srcH);
      final scaledW = (srcW * scale).round();
      final scaledH = (srcH * scale).round();
      final padX = ((inputSize - scaledW) / 2).round();
      final padY = ((inputSize - scaledH) / 2).round();
      // Crop region in output coordinates (4× of input padding).
      final cropX = padX * 4;
      final cropY = padY * 4;
      final cropW = scaledW * 4;
      final cropH = scaledH * 4;
      final rgba = _chwToRgbaCropped(
        outputBuffer, outputSize, outputSize,
        cropX, cropY, cropW, cropH,
      );
      postSw.stop();
      _log.d('postprocessed', {'ms': postSw.elapsedMilliseconds});

      // 6. Re-upload as a ui.Image at the cropped dimensions.
      final image = await BgRemovalImageIo.encodeRgbaToUiImage(
        rgba: rgba,
        width: cropW,
        height: cropH,
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
    } on SuperResException {
      rethrow;
    } on BgRemovalIoException catch (e) {
      total.stop();
      throw SuperResException(e.message, cause: e);
    } catch (e, st) {
      total.stop();
      _log.e('run failed',
          error: e, stackTrace: st, data: {'ms': total.elapsedMilliseconds});
      throw SuperResException(e.toString(), cause: e);
    }
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _log.i('close');
    await session.close();
  }

  /// Build [1][dstSize][dstSize][3] HWC tensor with letterboxing.
  /// The source image is scaled to fit inside dstSize×dstSize while
  /// preserving aspect ratio, centered with black padding.
  static List<List<List<List<double>>>> _buildLetterboxedHwcTensor({
    required Uint8List rgba,
    required int srcWidth,
    required int srcHeight,
    required int dstSize,
  }) {
    final scale = dstSize / (srcWidth > srcHeight ? srcWidth : srcHeight);
    final scaledW = (srcWidth * scale).round();
    final scaledH = (srcHeight * scale).round();
    final padX = ((dstSize - scaledW) / 2).round();
    final padY = ((dstSize - scaledH) / 2).round();

    final yScale = scaledH > 1 ? (srcHeight - 1) / (scaledH - 1) : 0.0;
    final xScale = scaledW > 1 ? (srcWidth - 1) / (scaledW - 1) : 0.0;

    return [
      List.generate(dstSize, (dy) {
        return List.generate(dstSize, (dx) {
          // Check if pixel is in the padded (black) region.
          final iy = dy - padY;
          final ix = dx - padX;
          if (iy < 0 || iy >= scaledH || ix < 0 || ix >= scaledW) {
            return [0.0, 0.0, 0.0]; // black padding
          }
          // Bilinear sample from source.
          final sy = iy * yScale;
          final y0 = sy.floor().clamp(0, srcHeight - 1);
          final y1 = (y0 + 1).clamp(0, srcHeight - 1);
          final wy = sy - y0;
          final sx = ix * xScale;
          final x0 = sx.floor().clamp(0, srcWidth - 1);
          final x1 = (x0 + 1).clamp(0, srcWidth - 1);
          final wx = sx - x0;

          final i00 = (y0 * srcWidth + x0) * 4;
          final i01 = (y0 * srcWidth + x1) * 4;
          final i10 = (y1 * srcWidth + x0) * 4;
          final i11 = (y1 * srcWidth + x1) * 4;

          final r = ((rgba[i00] * (1 - wx) + rgba[i01] * wx) * (1 - wy) +
                  (rgba[i10] * (1 - wx) + rgba[i11] * wx) * wy) /
              255.0;
          final g =
              ((rgba[i00 + 1] * (1 - wx) + rgba[i01 + 1] * wx) * (1 - wy) +
                      (rgba[i10 + 1] * (1 - wx) + rgba[i11 + 1] * wx) * wy) /
                  255.0;
          final b =
              ((rgba[i00 + 2] * (1 - wx) + rgba[i01 + 2] * wx) * (1 - wy) +
                      (rgba[i10 + 2] * (1 - wx) + rgba[i11 + 2] * wx) * wy) /
                  255.0;
          return [r, g, b];
        });
      })
    ];
  }

  /// Convert [3][H][W] CHW floats to RGBA, cropping a sub-region.
  static Uint8List _chwToRgbaCropped(
    List<List<List<double>>> chw,
    int fullW,
    int fullH,
    int cropX,
    int cropY,
    int cropW,
    int cropH,
  ) {
    final out = Uint8List(cropW * cropH * 4);
    for (int y = 0; y < cropH; y++) {
      final sy = (cropY + y).clamp(0, fullH - 1);
      for (int x = 0; x < cropW; x++) {
        final sx = (cropX + x).clamp(0, fullW - 1);
        final idx = (y * cropW + x) * 4;
        out[idx] = (chw[0][sy][sx].clamp(0.0, 1.0) * 255).round();
        out[idx + 1] = (chw[1][sy][sx].clamp(0.0, 1.0) * 255).round();
        out[idx + 2] = (chw[2][sy][sx].clamp(0.0, 1.0) * 255).round();
        out[idx + 3] = 255;
      }
    }
    return out;
  }
}

class SuperResException implements Exception {
  const SuperResException(this.message, {this.cause});
  final String message;
  final Object? cause;

  @override
  String toString() {
    if (cause == null) return 'SuperResException: $message';
    return 'SuperResException: $message (caused by $cause)';
  }
}
