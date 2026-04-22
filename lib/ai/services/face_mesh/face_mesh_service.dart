import 'dart:typed_data';
import 'dart:ui' as ui;

import '../../../core/logging/app_logger.dart';
import '../../runtime/litert_runtime.dart';

final _log = AppLogger('FaceMeshService');

/// Wraps the MediaPipe Face Landmark (Face Mesh) TFLite model — a
/// 468-point 3-D landmark regressor that runs on a pre-cropped face
/// patch.
///
/// Input:  `[1, 192, 192, 3]` float32 in `[0, 1]` (HWC, sRGB-encoded
/// pixels, no mean/std normalisation).
///
/// Outputs:
///   - `landmarks`: `[1, 1, 1, 1404]` float32 — 468 × (x, y, z). The
///      `x` and `y` coordinates are in the 0..192 crop pixel space;
///      `z` is a signed depth relative to face centre, roughly in
///      crop-pixel units.
///   - `flag`: `[1, 1, 1, 1]` float32 — a face-presence confidence
///      score in 0..1 (not quite a probability — MediaPipe clamps it
///      at the post-processor, but for gating inference it works like
///      one).
///
/// This service runs the model on a caller-provided RGBA buffer and a
/// face bounding box (usually from [FaceDetectionService]). It
/// crops → resizes to 192×192 → runs inference → un-maps landmarks
/// back to the caller's coordinate space. No model download: the
/// tflite ships in `assets/models/bundled/face_mesh.tflite` and is
/// wired via `face_mesh` in `assets/models/manifest.json`.
///
/// The classic face_landmark.tflite (no attention) is what we ship —
/// it returns 468 landmarks covering the face mesh vertices in the
/// MediaPipe canonical topology. When we need iris / refined-lips
/// landmarks later, the `with_attention` variant (478 points) can
/// drop in as a second manifest entry without service changes.
class FaceMeshService {
  FaceMeshService({
    required this.session,
    this.contextPaddingFraction = 0.25,
    this.confidenceThreshold = 0.5,
  });

  /// Native input resolution of the face_landmark model.
  static const int inputSize = 192;

  /// Number of 3-D landmarks the classic model emits.
  static const int landmarkCount = 468;

  /// Owned LiteRT session — the service closes it in [close].
  final LiteRtSession session;

  /// Fraction of the face bounding-box width / height to pad on each
  /// side before cropping the 192-input. The ML Kit face box is
  /// tight on the face; the landmark model was trained on a looser
  /// crop that includes forehead and chin margin, so padding here
  /// materially improves landmark accuracy.
  final double contextPaddingFraction;

  /// Minimum presence-flag value to accept the result. Below this
  /// threshold the crop probably didn't contain a face (detector
  /// false-positive, heavy occlusion) and [runOnRgba] returns null.
  final double confidenceThreshold;

  bool _closed = false;

  /// Run face mesh inference on a face region inside [sourceRgba].
  ///
  /// - [sourceRgba]: RGBA8 buffer, [sourceWidth] × [sourceHeight].
  /// - [faceBoundingBox]: the detected face box in the SAME pixel
  ///   coordinate space as the RGBA buffer. Callers that already
  ///   scale from face-detection resolution to service-decode
  ///   resolution should do that scaling before calling in.
  ///
  /// Returns null when either the model rejects the crop (confidence
  /// < [confidenceThreshold]) or the bounding box is degenerate. The
  /// null-return path is logged at `warning` level so post-hoc triage
  /// can distinguish "couldn't find a face" from "detector crashed".
  Future<FaceMeshResult?> runOnRgba({
    required Uint8List sourceRgba,
    required int sourceWidth,
    required int sourceHeight,
    required ui.Rect faceBoundingBox,
  }) async {
    if (_closed) {
      throw const FaceMeshException('FaceMeshService is closed');
    }
    if (sourceRgba.length != sourceWidth * sourceHeight * 4) {
      throw ArgumentError(
        'sourceRgba length ${sourceRgba.length} != '
        '${sourceWidth * sourceHeight * 4}',
      );
    }
    final total = Stopwatch()..start();

    // 1. Expand the bounding box for context, clamped to image bounds.
    final bbox = _expandBbox(
      original: faceBoundingBox,
      maxWidth: sourceWidth,
      maxHeight: sourceHeight,
      paddingFraction: contextPaddingFraction,
    );
    if (bbox.width < 8 || bbox.height < 8) {
      _log.w('bounding box too small after clamping', {
        'w': bbox.width.toStringAsFixed(1),
        'h': bbox.height.toStringAsFixed(1),
      });
      return null;
    }

    // 2. Build the 192×192 HWC tensor from the padded crop.
    final preSw = Stopwatch()..start();
    final inputTensor = _buildCropHwcTensor(
      rgba: sourceRgba,
      srcWidth: sourceWidth,
      srcHeight: sourceHeight,
      cropLeft: bbox.left,
      cropTop: bbox.top,
      cropWidth: bbox.width,
      cropHeight: bbox.height,
    );
    preSw.stop();

    // 3. Allocate the output tensors. The landmark model has two
    //    outputs — landmarks at index 0 and the presence flag at
    //    index 1 (verified by the MediaPipe graph .pbtxt).
    final landmarksOut = List.generate(
      1,
      (_) => List.generate(
        1,
        (_) => List.generate(
          1,
          (_) => List<double>.filled(landmarkCount * 3, 0.0),
        ),
      ),
    );
    final flagOut = List.generate(
      1,
      (_) => List.generate(
        1,
        (_) => List.generate(1, (_) => List<double>.filled(1, 0.0)),
      ),
    );

    // 4. Run.
    final inferSw = Stopwatch()..start();
    try {
      await session.runTyped(
        [inputTensor],
        {0: landmarksOut, 1: flagOut},
      );
    } catch (e, st) {
      _log.e('inference failed', error: e, stackTrace: st);
      throw FaceMeshException(e.toString(), cause: e);
    }
    inferSw.stop();

    final confidence = flagOut[0][0][0][0];
    if (confidence < confidenceThreshold) {
      total.stop();
      _log.w('below confidence threshold', {
        'confidence': confidence.toStringAsFixed(3),
        'threshold': confidenceThreshold,
        'ms': total.elapsedMilliseconds,
      });
      return null;
    }

    // 5. Decode the flat 1404 tensor into (x, y, z) lists and un-map
    //    from 192-space back into source-image coordinates.
    final postSw = Stopwatch()..start();
    final flat = landmarksOut[0][0][0];
    final landmarks = List<ui.Offset>.filled(
      landmarkCount,
      ui.Offset.zero,
      growable: false,
    );
    final depths = Float32List(landmarkCount);
    final sx = bbox.width / inputSize;
    final sy = bbox.height / inputSize;
    // z is in crop-pixel units in the model's native space; we scale
    // by the same horizontal factor so it stays comparable to x/y.
    final sz = bbox.width / inputSize;
    for (int i = 0; i < landmarkCount; i++) {
      final base = i * 3;
      final lx = flat[base];
      final ly = flat[base + 1];
      final lz = flat[base + 2];
      landmarks[i] = ui.Offset(
        bbox.left + lx * sx,
        bbox.top + ly * sy,
      );
      depths[i] = lz * sz;
    }
    postSw.stop();

    total.stop();
    _log.i('mesh complete', {
      'totalMs': total.elapsedMilliseconds,
      'preMs': preSw.elapsedMilliseconds,
      'inferMs': inferSw.elapsedMilliseconds,
      'postMs': postSw.elapsedMilliseconds,
      'confidence': confidence.toStringAsFixed(3),
    });

    return FaceMeshResult(
      landmarks: landmarks,
      landmarkDepths: depths,
      confidence: confidence,
      cropBbox: bbox,
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

  // ------------------------------------------------------------------
  // Helpers
  // ------------------------------------------------------------------

  static ui.Rect _expandBbox({
    required ui.Rect original,
    required int maxWidth,
    required int maxHeight,
    required double paddingFraction,
  }) {
    final padX = original.width * paddingFraction;
    final padY = original.height * paddingFraction;
    final left = (original.left - padX).clamp(0.0, maxWidth.toDouble());
    final top = (original.top - padY).clamp(0.0, maxHeight.toDouble());
    final right = (original.right + padX).clamp(0.0, maxWidth.toDouble());
    final bottom = (original.bottom + padY).clamp(0.0, maxHeight.toDouble());
    return ui.Rect.fromLTRB(left, top, right, bottom);
  }

  /// Build a nested `[1][192][192][3]` tensor from a rectangular crop
  /// of [rgba]. Bilinear-samples the source so a tight face box still
  /// produces smooth input.
  static List<List<List<List<double>>>> _buildCropHwcTensor({
    required Uint8List rgba,
    required int srcWidth,
    required int srcHeight,
    required double cropLeft,
    required double cropTop,
    required double cropWidth,
    required double cropHeight,
  }) {
    final xScale = cropWidth / (inputSize > 1 ? inputSize - 1 : 1);
    final yScale = cropHeight / (inputSize > 1 ? inputSize - 1 : 1);
    return [
      List.generate(inputSize, (y) {
        final sy = cropTop + y * yScale;
        final y0 = sy.floor().clamp(0, srcHeight - 1);
        final y1 = (y0 + 1).clamp(0, srcHeight - 1);
        final wy = sy - y0;
        return List.generate(inputSize, (x) {
          final sx = cropLeft + x * xScale;
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

/// 468 landmarks in source-image coordinates plus the model's own
/// presence-flag confidence.
class FaceMeshResult {
  const FaceMeshResult({
    required this.landmarks,
    required this.landmarkDepths,
    required this.confidence,
    required this.cropBbox,
  });

  /// `(x, y)` in source-image pixel coordinates. Index stable across
  /// calls — MediaPipe Face Mesh topology. See
  /// [FaceMeshIndices] for the subsets the beauty services need.
  final List<ui.Offset> landmarks;

  /// `z` depth per landmark, roughly in source-pixel units (negative
  /// = closer to the camera than the face-mesh centroid).
  final Float32List landmarkDepths;

  /// Model-reported presence confidence (0..1).
  final double confidence;

  /// The padded crop that was fed to the network. Kept for debug
  /// overlays / logging — landmarks are already un-mapped to source
  /// coordinates.
  final ui.Rect cropBbox;
}

/// Canonical MediaPipe Face Mesh index groups — a curated subset of
/// the 468-point topology that the beauty services actually use.
///
/// Indices come from the MediaPipe project's `face_geometry` +
/// `face_mesh_connections` modules (canonical landmark topology,
/// v0.10). Every integer here is documented there; kept in one
/// place so the services don't carry magic numbers.
class FaceMeshIndices {
  const FaceMeshIndices._();

  /// Inner-mouth (teeth region) polyline — the ring of vertices
  /// tracing the opening between the lips when the mouth is open.
  /// Used by the teeth whitening service to paint only the enamel
  /// area instead of the whole lip disc.
  static const List<int> innerLips = [
    78, 95, 88, 178, 87, 14, 317, 402, 318, 324,
    308, 415, 310, 311, 312, 13, 82, 81, 80, 191,
  ];

  /// Upper-lip outer edge (top of the visible lip). Combined with
  /// [lowerLipOuter] this outlines the lip disc for landmark-based
  /// skin mask carving.
  static const List<int> upperLipOuter = [
    61, 185, 40, 39, 37, 0, 267, 269, 270, 409, 291,
  ];

  /// Lower-lip outer edge.
  static const List<int> lowerLipOuter = [
    61, 146, 91, 181, 84, 17, 314, 405, 321, 375, 291,
  ];

  /// Left eye ring (subject-left = viewer's right on a front-facing
  /// image). Used to carve the eye exclusion out of the skin mask and
  /// as a sclera target for the eye-brighten service.
  static const List<int> leftEye = [
    33, 7, 163, 144, 145, 153, 154, 155, 133,
    173, 157, 158, 159, 160, 161, 246,
  ];

  /// Right eye ring (subject-right).
  static const List<int> rightEye = [
    362, 382, 381, 380, 374, 373, 390, 249, 263,
    466, 388, 387, 386, 385, 384, 398,
  ];

  /// Left-eyebrow lower edge — carved from the skin mask so brow
  /// hairs aren't blurred when smoothing skin.
  static const List<int> leftEyebrow = [
    46, 53, 52, 65, 55, 70, 63, 105, 66, 107,
  ];

  /// Right-eyebrow lower edge.
  static const List<int> rightEyebrow = [
    276, 283, 282, 295, 285, 300, 293, 334, 296, 336,
  ];

  /// Face oval outline — the outermost ring in the mesh. Encloses
  /// the pixels the skin mask should cover before feature cutouts
  /// are applied.
  static const List<int> faceOval = [
    10, 338, 297, 332, 284, 251, 389, 356, 454, 323,
    361, 288, 397, 365, 379, 378, 400, 377, 152, 148,
    176, 149, 150, 136, 172, 58, 132, 93, 234, 127,
    162, 21, 54, 103, 67, 109,
  ];
}

/// Typed exception surface for Face Mesh failures.
class FaceMeshException implements Exception {
  const FaceMeshException(this.message, {this.cause});
  final String message;
  final Object? cause;

  @override
  String toString() {
    if (cause == null) return 'FaceMeshException: $message';
    return 'FaceMeshException: $message (caused by $cause)';
  }
}
