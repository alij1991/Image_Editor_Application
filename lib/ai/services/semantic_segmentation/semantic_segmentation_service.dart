import 'dart:typed_data';

import '../../../core/logging/app_logger.dart';
import '../../runtime/litert_runtime.dart';

final _log = AppLogger('SemanticSegmentationService');

/// Wraps the MediaPipe DeepLab V3 (PASCAL VOC 21-class) TFLite model.
///
/// Input:  `[1, 257, 257, 3]` float32 in `[0, 1]` (HWC).
/// Output: `[1, 257, 257, 21]` float32 per-class scores.
///
/// Classes follow the standard PASCAL VOC 2012 semantic segmentation
/// labels:
///
///   0 background     1 aeroplane      2 bicycle        3 bird
///   4 boat           5 bottle         6 bus            7 car
///   8 cat            9 chair         10 cow           11 diningtable
///  12 dog           13 horse         14 motorbike     15 person
///  16 pottedplant   17 sheep         18 sofa          19 train
///  20 tvmonitor
///
/// **Sky is NOT a class.** This model helps sky replacement by
/// flagging pixels we're SURE aren't sky (person, car, furniture,
/// animals) — the sky mask then multiplies by `1 - objectMask` to
/// reject those false positives from the colour/top-bias heuristic.
/// Positive sky detection still comes from [SkyMaskBuilder].
///
/// Owns its [LiteRtSession] — [close] releases it.
class SemanticSegmentationService {
  SemanticSegmentationService({required this.session});

  /// DeepLab V3 native input/output spatial resolution.
  static const int inputSize = 257;

  /// Number of PASCAL VOC classes (including background).
  static const int numClasses = 21;

  /// Background class index.
  static const int backgroundClass = 0;

  /// Person class index — the one that matters most for sky-replace
  /// portraits-with-sky.
  static const int personClass = 15;

  final LiteRtSession session;
  bool _closed = false;

  /// Run inference on [sourceRgba]. Returns the raw
  /// `[1, 257, 257, 21]` score tensor packed into a flat
  /// `Float32List` of length `257 × 257 × 21 = 1_388_349`.
  Future<SegmentationResult> runOnRgba({
    required Uint8List sourceRgba,
    required int sourceWidth,
    required int sourceHeight,
  }) async {
    if (_closed) {
      throw const SemanticSegmentationException('service is closed');
    }
    if (sourceRgba.length != sourceWidth * sourceHeight * 4) {
      throw ArgumentError(
        'sourceRgba length ${sourceRgba.length} != '
        '${sourceWidth * sourceHeight * 4}',
      );
    }

    final total = Stopwatch()..start();

    // 1. Build [1, 257, 257, 3] HWC input tensor.
    final preSw = Stopwatch()..start();
    final input = _buildHwcTensor(
      rgba: sourceRgba,
      srcWidth: sourceWidth,
      srcHeight: sourceHeight,
    );
    preSw.stop();

    // 2. Allocate output [1, 257, 257, 21].
    final output = List.generate(
      1,
      (_) => List.generate(
        inputSize,
        (_) => List.generate(
          inputSize,
          (_) => List<double>.filled(numClasses, 0.0),
        ),
      ),
    );

    // 3. Run.
    final inferSw = Stopwatch()..start();
    try {
      await session.runTyped([input], {0: output});
    } catch (e, st) {
      _log.e('inference failed', error: e, stackTrace: st);
      throw SemanticSegmentationException(e.toString(), cause: e);
    }
    inferSw.stop();

    // 4. Flatten.
    final postSw = Stopwatch()..start();
    final flat = Float32List(inputSize * inputSize * numClasses);
    final plane = output[0];
    for (int y = 0; y < inputSize; y++) {
      final row = plane[y];
      for (int x = 0; x < inputSize; x++) {
        final cell = row[x];
        final base = (y * inputSize + x) * numClasses;
        for (int c = 0; c < numClasses; c++) {
          flat[base + c] = cell[c];
        }
      }
    }
    postSw.stop();

    total.stop();
    _log.i('segmentation complete', {
      'totalMs': total.elapsedMilliseconds,
      'preMs': preSw.elapsedMilliseconds,
      'inferMs': inferSw.elapsedMilliseconds,
      'postMs': postSw.elapsedMilliseconds,
    });

    return SegmentationResult(
      scores: flat,
      width: inputSize,
      height: inputSize,
      numClasses: numClasses,
    );
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _log.i('close');
    try {
      await session.close();
    } catch (e, st) {
      _log.e('session close failed', error: e, stackTrace: st);
    }
  }

  /// Build a nested `[1][257][257][3]` tensor by bilinearly sampling
  /// the RGBA buffer.
  static List<List<List<List<double>>>> _buildHwcTensor({
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

/// Raw per-pixel class scores + utility accessors.
class SegmentationResult {
  const SegmentationResult({
    required this.scores,
    required this.width,
    required this.height,
    required this.numClasses,
  });

  /// Flat `width × height × numClasses` tensor in row-major pixel
  /// order, class-major within each pixel.
  final Float32List scores;
  final int width;
  final int height;
  final int numClasses;

  /// argmax over classes for each pixel. Returns a `width × height`
  /// byte buffer where each entry is the winning class index.
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

  /// Return a float mask where a pixel is 1.0 if its argmax falls in
  /// [classes], 0.0 otherwise. Used for "people + other objects"
  /// filtering in sky replacement.
  Float32List maskForClasses(Set<int> classes) {
    final am = argmax();
    final mask = Float32List(width * height);
    for (int i = 0; i < am.length; i++) {
      if (classes.contains(am[i])) mask[i] = 1.0;
    }
    return mask;
  }

  /// "Object-ness": 1.0 if the pixel's argmax is any class except
  /// background (0), 0.0 otherwise. Wraps the most common
  /// [maskForClasses] call for sky-replace's non-sky-object filter.
  Float32List objectMask() {
    final am = argmax();
    final mask = Float32List(width * height);
    for (int i = 0; i < am.length; i++) {
      if (am[i] != SemanticSegmentationService.backgroundClass) {
        mask[i] = 1.0;
      }
    }
    return mask;
  }

  /// Bilinearly resample a segmentation-space mask onto an arbitrary
  /// destination resolution. Used to align the 257×257 object mask
  /// with the decoded source buffer (typically 2048-wide).
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

class SemanticSegmentationException implements Exception {
  const SemanticSegmentationException(this.message, {this.cause});
  final String message;
  final Object? cause;

  @override
  String toString() {
    if (cause == null) return 'SemanticSegmentationException: $message';
    return 'SemanticSegmentationException: $message (caused by $cause)';
  }
}
