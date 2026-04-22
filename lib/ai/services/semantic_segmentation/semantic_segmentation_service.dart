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
  SemanticSegmentationService({
    required this.session,
    this.inputSize = pascalInputSize,
    this.numClasses = pascalNumClasses,
  });

  /// Convenience factory for the bundled MediaPipe DeepLab V3 PASCAL
  /// VOC model. 21-class output, 257 × 257 input. Use when you
  /// need a non-sky-object filter (person/car/animal/furniture) to
  /// reject from a colour-based sky mask.
  factory SemanticSegmentationService.pascal({
    required LiteRtSession session,
  }) {
    return SemanticSegmentationService(
      session: session,
      inputSize: pascalInputSize,
      numClasses: pascalNumClasses,
    );
  }

  /// Convenience factory for the bundled DeepLab V3 MobileNetV2
  /// ADE20K model. 151-class output (0=unlabeled, 1..150 = ADE20K
  /// scene-parsing categories), 513 × 513 input. Class 3 = sky.
  /// Use when you need positive-signal sky detection.
  factory SemanticSegmentationService.ade20k({
    required LiteRtSession session,
  }) {
    return SemanticSegmentationService(
      session: session,
      inputSize: ade20kInputSize,
      numClasses: ade20kNumClasses,
    );
  }

  /// PASCAL VOC DeepLab native input/output spatial resolution.
  static const int pascalInputSize = 257;

  /// PASCAL VOC class count (bg + 20 object classes).
  static const int pascalNumClasses = 21;

  /// ADE20K DeepLab native input/output spatial resolution.
  static const int ade20kInputSize = 513;

  /// ADE20K output class count (unlabeled + 150 scene categories).
  static const int ade20kNumClasses = 151;

  /// Background class index (shared across both trainings — for
  /// ADE20K this is the "unlabeled" slot that the model shouldn't
  /// emit in practice).
  static const int backgroundClass = 0;

  /// Person class index in PASCAL VOC — the one that matters most
  /// for sky-replace portraits-with-sky.
  static const int pascalPersonClass = 15;

  /// Sky class index in ADE20K scene parsing (see SceneParsing-150
  /// label list: wall=1, building=2, sky=3, floor=4, …).
  static const int ade20kSkyClass = 3;

  /// The network's native spatial input/output size. Both PASCAL and
  /// ADE20K DeepLabs output at the same resolution as their input.
  final int inputSize;

  /// Number of output classes. Callers use it to allocate the output
  /// tensor and to iterate argmax.
  final int numClasses;

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

    // 1. Build [1, inputSize, inputSize, 3] HWC input tensor. The
    //    input is small (≤ 513 × 513 × 3 ≈ 790k doubles ≈ 25 MB of
    //    boxed dynamic slots) so nested-list form is fine here.
    final preSw = Stopwatch()..start();
    final input = _buildHwcTensor(
      rgba: sourceRgba,
      srcWidth: sourceWidth,
      srcHeight: sourceHeight,
    );
    preSw.stop();

    // 2. Allocate the output as a raw byte buffer sized to
    //    `inputSize² × numClasses × 4`. flutter_litert's Tensor.copyTo
    //    takes a *linear byte copy* path when the caller passes a
    //    Uint8List dst — roughly free memory-wise. The nested-list
    //    path (the obvious `List.generate` pattern) would box every
    //    float as a `dynamic` + allocate grow-as-needed backing
    //    storage; at ADE20K resolution that's ~40 M floats ≈ 1 GB of
    //    Dart heap and blows iOS's main-thread 3.4 GB ceiling.
    final outputByteCount = inputSize * inputSize * numClasses * 4;
    final outputBytes = Uint8List(outputByteCount);

    // 3. Run.
    final inferSw = Stopwatch()..start();
    try {
      await session.runTyped([input], {0: outputBytes});
    } catch (e, st) {
      _log.e('inference failed', error: e, stackTrace: st);
      throw SemanticSegmentationException(e.toString(), cause: e);
    }
    inferSw.stop();

    // 4. Reinterpret the bytes as a Float32List view — zero-copy.
    //    The view shares outputBytes.buffer so the byte backing stays
    //    alive as long as the caller keeps SegmentationResult.scores.
    final postSw = Stopwatch()..start();
    final flat = Float32List.view(outputBytes.buffer);
    postSw.stop();

    total.stop();
    _log.i('segmentation complete', {
      'totalMs': total.elapsedMilliseconds,
      'preMs': preSw.elapsedMilliseconds,
      'inferMs': inferSw.elapsedMilliseconds,
      'postMs': postSw.elapsedMilliseconds,
      'outputBytes': outputByteCount,
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

  /// Build a nested `[1][inputSize][inputSize][3]` tensor by
  /// bilinearly sampling the RGBA buffer. Non-static so it can read
  /// the instance's `inputSize` field (PASCAL = 257, ADE20K = 513).
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
