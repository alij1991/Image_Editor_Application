import 'dart:typed_data';

import '../../../core/logging/app_logger.dart';
import '../../runtime/litert_runtime.dart';

final _log = AppLogger('SelfieMulticlassService');

/// Phase XV.2: wraps MediaPipe's Selfie Multiclass TFLite segmenter.
///
/// Input:  `[1, 256, 256, 3]` float32 in `[0, 1]` (HWC).
/// Output: `[1, 256, 256, 6]` float32 per-class logits.
///
/// Class indices (from MediaPipe's model card):
///   0 — background
///   1 — hair
///   2 — body-skin (arms, legs, torso)
///   3 — face-skin
///   4 — clothes
///   5 — others / accessories (hats, jewelry, glasses)
///
/// The service returns a [SelfieMulticlassResult] with a flat score
/// tensor plus helpers for argmax and per-class float masks.
///
/// Owns its [LiteRtSession] — [close] releases it.
class SelfieMulticlassService {
  SelfieMulticlassService({required this.session});

  /// Model's fixed spatial resolution.
  static const int inputSize = 256;

  /// Number of output classes.
  static const int numClasses = 6;

  static const int backgroundClass = 0;
  static const int hairClass = 1;
  static const int bodySkinClass = 2;
  static const int faceSkinClass = 3;
  static const int clothesClass = 4;
  static const int accessoriesClass = 5;

  final LiteRtSession session;
  bool _closed = false;

  /// Run segmentation on [sourceRgba] (`sourceWidth × sourceHeight`).
  /// Returns a [SelfieMulticlassResult] at 256×256 — callers that
  /// want the mask back at source resolution bilinear-resize the
  /// float mask via [SelfieMulticlassResult.bilinearResize].
  Future<SelfieMulticlassResult> runOnRgba({
    required Uint8List sourceRgba,
    required int sourceWidth,
    required int sourceHeight,
  }) async {
    if (_closed) {
      throw const SelfieMulticlassException('service is closed');
    }
    if (sourceRgba.length != sourceWidth * sourceHeight * 4) {
      throw ArgumentError(
        'sourceRgba length ${sourceRgba.length} != '
        '${sourceWidth * sourceHeight * 4}',
      );
    }

    final total = Stopwatch()..start();

    // 1. Build nested `[1][256][256][3]` float input. ~0.6 MB of
    //    Dart heap — cheap at this resolution.
    final preSw = Stopwatch()..start();
    final input = _buildHwcTensor(
      rgba: sourceRgba,
      srcWidth: sourceWidth,
      srcHeight: sourceHeight,
    );
    preSw.stop();

    // 2. Output tensor: 256 × 256 × 6 × 4 bytes = 1 572 864 bytes.
    //    Small enough that nested-list or byte-buffer form both
    //    work; byte buffer + Float32List.view is zero-copy though.
    final outputByteCount = inputSize * inputSize * numClasses * 4;
    final outputBytes = Uint8List(outputByteCount);

    final inferSw = Stopwatch()..start();
    try {
      await session.runTyped([input], {0: outputBytes});
    } catch (e, st) {
      _log.e('inference failed', error: e, stackTrace: st);
      throw SelfieMulticlassException(e.toString(), cause: e);
    }
    inferSw.stop();

    final flat = Float32List.view(outputBytes.buffer);
    total.stop();
    _log.i('segmentation complete', {
      'totalMs': total.elapsedMilliseconds,
      'preMs': preSw.elapsedMilliseconds,
      'inferMs': inferSw.elapsedMilliseconds,
    });

    return SelfieMulticlassResult(scores: flat);
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    try {
      await session.close();
    } catch (e, st) {
      _log.e('session close failed', error: e, stackTrace: st);
    }
  }

  List<List<List<List<double>>>> _buildHwcTensor({
    required Uint8List rgba,
    required int srcWidth,
    required int srcHeight,
  }) {
    final xScale = (srcWidth - 1) / (inputSize > 1 ? inputSize - 1 : 1);
    final yScale = (srcHeight - 1) / (inputSize > 1 ? inputSize - 1 : 1);
    return [
      List.generate(inputSize, (y) {
        final sy = y * yScale;
        final y0 = sy.floor().clamp(0, srcHeight - 1);
        final y1 = (y0 + 1).clamp(0, srcHeight - 1);
        final wy = sy - y0;
        return List.generate(inputSize, (x) {
          final sx = x * xScale;
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
      }),
    ];
  }
}

/// Raw `[256, 256, 6]` score tensor + helpers. Mirrors the
/// [SegmentationResult] surface from `semantic_segmentation_service.dart`
/// so callers can swap one for the other where class sets overlap.
class SelfieMulticlassResult {
  const SelfieMulticlassResult({required this.scores});

  /// Flat 256 × 256 × 6 float tensor (row-major pixel, class-major
  /// within each pixel).
  final Float32List scores;

  int get width => SelfieMulticlassService.inputSize;
  int get height => SelfieMulticlassService.inputSize;
  int get numClasses => SelfieMulticlassService.numClasses;

  /// argmax over classes for each pixel → `width × height` byte
  /// buffer of winning class indices.
  Uint8List argmax() {
    final out = Uint8List(width * height);
    for (int p = 0; p < width * height; p++) {
      final base = p * numClasses;
      int best = 0;
      double bestScore = scores[base];
      for (int c = 1; c < numClasses; c++) {
        final s = scores[base + c];
        if (s > bestScore) {
          bestScore = s;
          best = c;
        }
      }
      out[p] = best;
    }
    return out;
  }

  /// Return a float mask where each pixel is `1.0` when its argmax
  /// falls in [classes], otherwise `0.0`. Simple and discrete —
  /// the recolour path feathers the mask during bilinear upsample
  /// so hard argmax is fine at segmentation resolution.
  Float32List maskForClasses(Set<int> classes) {
    final am = argmax();
    final out = Float32List(width * height);
    for (int i = 0; i < am.length; i++) {
      if (classes.contains(am[i])) out[i] = 1.0;
    }
    return out;
  }

  /// Bilinearly resample a segmentation-space mask to an arbitrary
  /// destination resolution. The smooth interpolation across the
  /// discrete class boundary doubles as a light edge feather, which
  /// keeps recolour joins looking natural without a separate blur
  /// step.
  static Float32List bilinearResize({
    required Float32List src,
    required int srcWidth,
    required int srcHeight,
    required int dstWidth,
    required int dstHeight,
  }) {
    final out = Float32List(dstWidth * dstHeight);
    final xScale = srcWidth / dstWidth;
    final yScale = srcHeight / dstHeight;
    for (int dy = 0; dy < dstHeight; dy++) {
      final sy = (dy + 0.5) * yScale - 0.5;
      final y0 = sy.floor().clamp(0, srcHeight - 1);
      final y1 = (y0 + 1).clamp(0, srcHeight - 1);
      final wy = (sy - y0).clamp(0.0, 1.0);
      for (int dx = 0; dx < dstWidth; dx++) {
        final sx = (dx + 0.5) * xScale - 0.5;
        final x0 = sx.floor().clamp(0, srcWidth - 1);
        final x1 = (x0 + 1).clamp(0, srcWidth - 1);
        final wx = (sx - x0).clamp(0.0, 1.0);
        final v00 = src[y0 * srcWidth + x0];
        final v01 = src[y0 * srcWidth + x1];
        final v10 = src[y1 * srcWidth + x0];
        final v11 = src[y1 * srcWidth + x1];
        out[dy * dstWidth + dx] =
            (v00 * (1 - wx) + v01 * wx) * (1 - wy) +
                (v10 * (1 - wx) + v11 * wx) * wy;
      }
    }
    return out;
  }
}

class SelfieMulticlassException implements Exception {
  const SelfieMulticlassException(this.message, {this.cause});
  final String message;
  final Object? cause;

  @override
  String toString() {
    if (cause == null) return 'SelfieMulticlassException: $message';
    return 'SelfieMulticlassException: $message (caused by $cause)';
  }
}
