import 'dart:typed_data';
import 'dart:ui' as ui;

import '../../../core/logging/app_logger.dart';
import '../../runtime/litert_runtime.dart';
import 'coco_labels.dart';

final _log = AppLogger('ObjectDetectorService');

/// Wraps the bundled EfficientDet-Lite0 (with TFLite_Detection_PostProcess
/// baked into the graph) as a caller-friendly object detector.
///
/// Input:  `[1, 320, 320, 3]` uint8. The model's quantisation layer
///          maps raw uint8 pixels through `(v - 127) * (1/128)` so
///          callers pass the pixel buffer unchanged; no normalisation
///          in Dart.
///
/// Outputs (with TFLite_Detection_PostProcess applied):
///   - 0: locations `[1, 25, 4]` float32 — (ymin, xmin, ymax, xmax)
///        in `[0, 1]` normalised image coordinates.
///   - 1: classes   `[1, 25]`    float32 — COCO-90 class index as a
///        float (cast to int).
///   - 2: scores    `[1, 25]`    float32 — confidence in `[0, 1]`.
///   - 3: count     `[1]`        float32 — number of valid detections
///        in the first N slots (rest are zero-padded).
///
/// The service does the standard work:
///   1. Bilinear-resize the RGBA source buffer to 320×320 RGB bytes.
///   2. Run inference on the isolate.
///   3. Filter by [minScore], cap to [maxDetections], un-normalise the
///      bboxes back into the caller's pixel space.
///
/// It deliberately does NOT own the COCO label map — callers ask for
/// the label via [CocoLabels.labelFor] so the service stays
/// dependency-light.
class ObjectDetectorService {
  ObjectDetectorService({
    required this.session,
    this.minScore = 0.3,
    this.maxDetections = 25,
  });

  /// Factory for the bundled EfficientDet-Lite0 detection-default
  /// model (320×320, 25 boxes, NMS baked in).
  factory ObjectDetectorService.efficientDetLite0({
    required LiteRtSession session,
    double minScore = 0.3,
  }) {
    return ObjectDetectorService(
      session: session,
      minScore: minScore,
      maxDetections: 25,
    );
  }

  /// Native model input resolution.
  static const int inputSize = 320;

  /// The model's fixed top-N output buffer size. Detections beyond this
  /// cap are discarded by the PostProcess op — there is no way to
  /// retrieve them.
  static const int outputCapacity = 25;

  final LiteRtSession session;

  /// Detections with score below this threshold are dropped.
  final double minScore;

  /// Upper bound on detections returned. Must be ≤ [outputCapacity].
  final int maxDetections;

  bool _closed = false;

  /// Run detection on [sourceRgba] (`sourceWidth × sourceHeight`).
  ///
  /// Returns a list of [ObjectDetection]s sorted by descending score.
  /// Bounding boxes are in the caller's pixel coordinate space.
  Future<List<ObjectDetection>> runOnRgba({
    required Uint8List sourceRgba,
    required int sourceWidth,
    required int sourceHeight,
  }) async {
    if (_closed) {
      throw const ObjectDetectorException('service is closed');
    }
    if (sourceRgba.length != sourceWidth * sourceHeight * 4) {
      throw ArgumentError(
        'sourceRgba length ${sourceRgba.length} != '
        '${sourceWidth * sourceHeight * 4}',
      );
    }

    final total = Stopwatch()..start();

    // 1. Resize RGBA → 320×320 RGB uint8. Flat Uint8List passes through
    //    ByteConversionUtils without nested-list boxing overhead.
    final preSw = Stopwatch()..start();
    final input = _buildInputBytes(
      rgba: sourceRgba,
      srcWidth: sourceWidth,
      srcHeight: sourceHeight,
    );
    preSw.stop();

    // 2. Allocate nested-list outputs. Four tiny tensors — 101 floats
    //    total — so nesting is fine here.
    final locations = List.generate(
      1,
      (_) => List.generate(
        outputCapacity,
        (_) => List<double>.filled(4, 0.0),
      ),
    );
    final classes = List.generate(
      1,
      (_) => List<double>.filled(outputCapacity, 0.0),
    );
    final scores = List.generate(
      1,
      (_) => List<double>.filled(outputCapacity, 0.0),
    );
    final count = List<double>.filled(1, 0.0);

    // 3. Inference.
    final inferSw = Stopwatch()..start();
    try {
      await session.runTyped([input], {
        0: locations,
        1: classes,
        2: scores,
        3: count,
      });
    } catch (e, st) {
      _log.e('inference failed', error: e, stackTrace: st);
      throw ObjectDetectorException(e.toString(), cause: e);
    }
    inferSw.stop();

    // 4. Decode. `count[0]` is the valid-slot count; beyond that the
    //    PostProcess op pads with zeros so we rely on the count *and*
    //    [minScore] as a belt-and-braces filter.
    final postSw = Stopwatch()..start();
    final validCount = count[0].toInt().clamp(0, outputCapacity);
    final out = <ObjectDetection>[];
    for (int i = 0; i < validCount && i < maxDetections; i++) {
      final score = scores[0][i];
      if (score < minScore) continue;
      final box = locations[0][i];
      // Model order: ymin, xmin, ymax, xmax in normalised [0, 1].
      final ymin = box[0].clamp(0.0, 1.0);
      final xmin = box[1].clamp(0.0, 1.0);
      final ymax = box[2].clamp(0.0, 1.0);
      final xmax = box[3].clamp(0.0, 1.0);
      if (xmax <= xmin || ymax <= ymin) continue;
      out.add(
        ObjectDetection(
          bbox: ui.Rect.fromLTRB(
            xmin * sourceWidth,
            ymin * sourceHeight,
            xmax * sourceWidth,
            ymax * sourceHeight,
          ),
          classIndex: classes[0][i].toInt(),
          score: score,
        ),
      );
    }
    out.sort((a, b) => b.score.compareTo(a.score));
    postSw.stop();

    total.stop();
    _log.i('detect complete', {
      'totalMs': total.elapsedMilliseconds,
      'preMs': preSw.elapsedMilliseconds,
      'inferMs': inferSw.elapsedMilliseconds,
      'postMs': postSw.elapsedMilliseconds,
      'validCount': validCount,
      'kept': out.length,
    });
    return out;
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

  /// Build a flat `320 × 320 × 3` Uint8 buffer by bilinearly sampling
  /// the RGBA source. Passing a Uint8List short-circuits the
  /// nested-list serializer in ByteConversionUtils — far cheaper than
  /// 307k boxed ints.
  static Uint8List _buildInputBytes({
    required Uint8List rgba,
    required int srcWidth,
    required int srcHeight,
  }) {
    final out = Uint8List(inputSize * inputSize * 3);
    final xScale = (srcWidth - 1) / (inputSize > 1 ? inputSize - 1 : 1);
    final yScale = (srcHeight - 1) / (inputSize > 1 ? inputSize - 1 : 1);
    int w = 0;
    for (int y = 0; y < inputSize; y++) {
      final sy = y * yScale;
      final y0 = sy.floor().clamp(0, srcHeight - 1);
      final y1 = (y0 + 1).clamp(0, srcHeight - 1);
      final wy = sy - y0;
      for (int x = 0; x < inputSize; x++) {
        final sx = x * xScale;
        final x0 = sx.floor().clamp(0, srcWidth - 1);
        final x1 = (x0 + 1).clamp(0, srcWidth - 1);
        final wx = sx - x0;
        final i00 = (y0 * srcWidth + x0) * 4;
        final i01 = (y0 * srcWidth + x1) * 4;
        final i10 = (y1 * srcWidth + x0) * 4;
        final i11 = (y1 * srcWidth + x1) * 4;
        final r = (rgba[i00] * (1 - wx) + rgba[i01] * wx) * (1 - wy) +
            (rgba[i10] * (1 - wx) + rgba[i11] * wx) * wy;
        final g = (rgba[i00 + 1] * (1 - wx) + rgba[i01 + 1] * wx) * (1 - wy) +
            (rgba[i10 + 1] * (1 - wx) + rgba[i11 + 1] * wx) * wy;
        final b = (rgba[i00 + 2] * (1 - wx) + rgba[i01 + 2] * wx) * (1 - wy) +
            (rgba[i10 + 2] * (1 - wx) + rgba[i11 + 2] * wx) * wy;
        out[w++] = r.round().clamp(0, 255);
        out[w++] = g.round().clamp(0, 255);
        out[w++] = b.round().clamp(0, 255);
      }
    }
    return out;
  }
}

/// A single detection: bbox in source-image pixel space, COCO-90 class
/// index, and a `[0, 1]` score.
class ObjectDetection {
  const ObjectDetection({
    required this.bbox,
    required this.classIndex,
    required this.score,
  });

  final ui.Rect bbox;
  final int classIndex;
  final double score;

  /// Convenience: look up the English label for this detection's
  /// class index via [CocoLabels.labelFor]. Returns null for classes
  /// outside the 90-slot table (unused reserved slots).
  String? get label => CocoLabels.labelFor(classIndex);

  @override
  String toString() =>
      'ObjectDetection(${label ?? 'class=$classIndex'}, '
      'score=${score.toStringAsFixed(2)}, bbox=$bbox)';
}

class ObjectDetectorException implements Exception {
  const ObjectDetectorException(this.message, {this.cause});
  final String message;
  final Object? cause;

  @override
  String toString() {
    if (cause == null) return 'ObjectDetectorException: $message';
    return 'ObjectDetectorException: $message (caused by $cause)';
  }
}
