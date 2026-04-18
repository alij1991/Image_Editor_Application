import 'dart:math';
import 'dart:ui' as ui;

import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart'
    as mlkit;

import '../../../core/logging/app_logger.dart';

final _log = AppLogger('FaceDetectionService');

/// Wraps Google ML Kit's [mlkit.FaceDetector] and returns a typed
/// list of [DetectedFace] results.
///
/// Kept intentionally thin: the service owns the ML Kit detector
/// handle, logs every lifecycle event, and surfaces inference
/// failures through a typed [FaceDetectionException] so the UI can
/// render distinct error states for "no face detected" vs "detector
/// crashed".
///
/// The detector is bundled with the ML Kit plugin — no manifest
/// entry or download required. Landmarks are opted-in (`enableLandmarks:
/// true`) so the face mask builder in Phase 9d's portrait-smooth
/// pipeline can eventually carve out eyes and mouth; contours are
/// off by default because they roughly 4× the per-face payload and
/// we don't need them for Phase 9d's basic feature set.
class FaceDetectionService {
  FaceDetectionService({
    mlkit.FaceDetector? detector,
    this.minFaceSize = 0.1,
    this.enableContours = true,
  }) : _detector = detector ??
            mlkit.FaceDetector(
              options: mlkit.FaceDetectorOptions(
                performanceMode: mlkit.FaceDetectorMode.accurate,
                enableLandmarks: true,
                enableClassification: false,
                enableContours: enableContours,
                enableTracking: false,
                minFaceSize: minFaceSize,
              ),
            ) {
    _log.i('created', {
      'minFaceSize': minFaceSize,
      'mode': 'accurate',
      'landmarks': true,
      'classification': false,
      'contours': enableContours,
      'tracking': false,
      'injectedDetector': detector != null,
    });
  }

  final mlkit.FaceDetector _detector;

  /// Ignore faces smaller than this fraction of the image width.
  /// Defaults to 10% — the ML Kit default.
  final double minFaceSize;

  /// When true, the ML Kit detector runs an additional contour pass
  /// that yields ~130 points per face (face outline, eyes, lips,
  /// eyebrows, nose). Phase 9d/9e only needed the 6 named landmarks
  /// so this was off by default; Phase 9f enables it for the face
  /// reshape pipeline, which needs a full outline to build the
  /// warp field.
  ///
  /// Contours roughly double detector latency, so callers that
  /// don't need them should leave this off.
  final bool enableContours;

  bool _closed = false;

  /// Detect faces in the image at [sourcePath]. Returns an empty
  /// list when the detector runs successfully but finds no faces.
  /// Throws [FaceDetectionException] on detector failure.
  Future<List<DetectedFace>> detectFromPath(String sourcePath) async {
    if (_closed) {
      _log.w('detect rejected — service closed', {'path': sourcePath});
      throw const FaceDetectionException('FaceDetectionService is closed');
    }
    final sw = Stopwatch()..start();
    _log.i('detect start', {'path': sourcePath});
    try {
      final inputImage = mlkit.InputImage.fromFilePath(sourcePath);
      final rawFaces = await _detector.processImage(inputImage);
      if (rawFaces.isEmpty) {
        sw.stop();
        _log.i('detect complete', {
          'ms': sw.elapsedMilliseconds,
          'count': 0,
        });
        return const [];
      }
      final out = <DetectedFace>[];
      for (final raw in rawFaces) {
        final converted = _convertFace(raw);
        _log.d('face detected', converted.toLogMap());
        out.add(converted);
      }
      sw.stop();
      _log.i('detect complete', {
        'ms': sw.elapsedMilliseconds,
        'count': out.length,
      });
      return out;
    } on FaceDetectionException {
      rethrow;
    } catch (e, st) {
      sw.stop();
      _log.e('detect failed',
          error: e,
          stackTrace: st,
          data: {'ms': sw.elapsedMilliseconds, 'path': sourcePath});
      throw FaceDetectionException('Detector failed: $e', cause: e);
    }
  }

  /// Release the underlying ML Kit handle. Safe to call multiple times.
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _log.i('close');
    try {
      await _detector.close();
    } catch (e, st) {
      // Swallow the exception — we're in a teardown path and the
      // caller can't do anything useful about a close failure — but
      // capture the full stack trace at error level so a leaked
      // native handle trace survives in logs. Method-channel errors
      // from ML Kit have historically been hard to reproduce without
      // the original frame.
      _log.e('detector close failed', error: e, stackTrace: st);
    }
  }

  // ----- internals ---------------------------------------------------------

  static DetectedFace _convertFace(mlkit.Face raw) {
    final bb = raw.boundingBox;
    final landmarks = <FaceLandmark, ui.Offset>{};
    for (final entry in raw.landmarks.entries) {
      final lm = entry.value;
      if (lm == null) continue;
      final key = FaceLandmarkX.fromMlKit(entry.key);
      if (key == null) continue;
      landmarks[key] = ui.Offset(
        lm.position.x.toDouble(),
        lm.position.y.toDouble(),
      );
    }
    // Contours are always captured even when the detector wasn't
    // asked for them (the map will just be empty). Keeps the
    // [DetectedFace] shape uniform regardless of detector options.
    final contours = <FaceContour, List<ui.Offset>>{};
    for (final entry in raw.contours.entries) {
      final contour = entry.value;
      if (contour == null || contour.points.isEmpty) continue;
      final key = FaceContourX.fromMlKit(entry.key);
      if (key == null) continue;
      contours[key] = [
        for (final p in contour.points)
          ui.Offset(p.x.toDouble(), p.y.toDouble()),
      ];
    }
    return DetectedFace(
      boundingBox: ui.Rect.fromLTWH(bb.left, bb.top, bb.width, bb.height),
      landmarks: landmarks,
      contours: contours,
      headEulerAngleZ: raw.headEulerAngleZ ?? 0.0,
    );
  }
}

/// A single face detected by [FaceDetectionService]. The bounding box,
/// landmarks, and contours are all in **source-image pixel
/// coordinates** — callers are responsible for scaling to preview
/// resolution if needed.
///
/// Only a subset of the ML Kit landmark set is exposed — we promote
/// the ones Phase 9d's beautification pipeline actually uses.
/// [contours] is populated only when the detector was built with
/// `enableContours: true` (Phase 9f's face reshape); otherwise the
/// map is empty.
class DetectedFace {
  const DetectedFace({
    required this.boundingBox,
    required this.landmarks,
    required this.headEulerAngleZ,
    this.contours = const {},
  });

  final ui.Rect boundingBox;
  final Map<FaceLandmark, ui.Offset> landmarks;

  /// Contour polylines in source-image pixels. Empty when the
  /// detector was not built with `enableContours: true`.
  final Map<FaceContour, List<ui.Offset>> contours;

  /// Z-axis rotation in degrees, positive = counter-clockwise.
  /// Used by the mask builder to orient the eye/mouth exclusion
  /// zones when the face is tilted.
  final double headEulerAngleZ;

  /// Convenience: the geometric center of the detected bounding box.
  ui.Offset get center => boundingBox.center;

  /// Total number of contour points across every contour type.
  /// Used in logs so we can see at a glance how much outline data
  /// the reshape service has to work with.
  int get contourPointCount {
    int total = 0;
    for (final pts in contours.values) {
      total += pts.length;
    }
    return total;
  }

  Map<String, Object?> toLogMap() => {
        'boundingBox': '${boundingBox.left.round()},${boundingBox.top.round()} '
            '${boundingBox.width.round()}x${boundingBox.height.round()}',
        'landmarks': landmarks.length,
        'contours': contours.length,
        'contourPoints': contourPointCount,
        'angleZ': headEulerAngleZ.toStringAsFixed(1),
      };
}

/// Promoted subset of `mlkit.FaceLandmarkType`. Phase 9d uses the eye
/// + mouth points to carve exclusion holes in the face-smoothing mask
/// (so eyes and lips stay sharp). Other landmark types are ignored
/// until a feature actually needs them.
enum FaceLandmark {
  leftEye,
  rightEye,
  noseBase,
  leftMouth,
  rightMouth,
  bottomMouth,
}

extension FaceLandmarkX on FaceLandmark {
  static FaceLandmark? fromMlKit(mlkit.FaceLandmarkType t) {
    switch (t) {
      case mlkit.FaceLandmarkType.leftEye:
        return FaceLandmark.leftEye;
      case mlkit.FaceLandmarkType.rightEye:
        return FaceLandmark.rightEye;
      case mlkit.FaceLandmarkType.noseBase:
        return FaceLandmark.noseBase;
      case mlkit.FaceLandmarkType.leftMouth:
        return FaceLandmark.leftMouth;
      case mlkit.FaceLandmarkType.rightMouth:
        return FaceLandmark.rightMouth;
      case mlkit.FaceLandmarkType.bottomMouth:
        return FaceLandmark.bottomMouth;
      case mlkit.FaceLandmarkType.leftEar:
      case mlkit.FaceLandmarkType.rightEar:
      case mlkit.FaceLandmarkType.leftCheek:
      case mlkit.FaceLandmarkType.rightCheek:
        return null;
    }
  }
}

/// Promoted subset of `mlkit.FaceContourType`. Phase 9f's face
/// reshape pipeline uses `face` (outline for slim-face pulls),
/// `leftEye` / `rightEye` (closed loops for enlarge-eyes), and
/// `upperLipTop` / `lowerLipBottom` (lip carving, future). Other
/// contours pass through unchanged and are captured in the
/// [DetectedFace.contours] map for future features.
enum FaceContour {
  face,
  leftEye,
  rightEye,
  leftEyebrowTop,
  leftEyebrowBottom,
  rightEyebrowTop,
  rightEyebrowBottom,
  upperLipTop,
  upperLipBottom,
  lowerLipTop,
  lowerLipBottom,
  noseBridge,
  noseBottom,
}

extension FaceContourX on FaceContour {
  static FaceContour? fromMlKit(mlkit.FaceContourType t) {
    switch (t) {
      case mlkit.FaceContourType.face:
        return FaceContour.face;
      case mlkit.FaceContourType.leftEye:
        return FaceContour.leftEye;
      case mlkit.FaceContourType.rightEye:
        return FaceContour.rightEye;
      case mlkit.FaceContourType.leftEyebrowTop:
        return FaceContour.leftEyebrowTop;
      case mlkit.FaceContourType.leftEyebrowBottom:
        return FaceContour.leftEyebrowBottom;
      case mlkit.FaceContourType.rightEyebrowTop:
        return FaceContour.rightEyebrowTop;
      case mlkit.FaceContourType.rightEyebrowBottom:
        return FaceContour.rightEyebrowBottom;
      case mlkit.FaceContourType.upperLipTop:
        return FaceContour.upperLipTop;
      case mlkit.FaceContourType.upperLipBottom:
        return FaceContour.upperLipBottom;
      case mlkit.FaceContourType.lowerLipTop:
        return FaceContour.lowerLipTop;
      case mlkit.FaceContourType.lowerLipBottom:
        return FaceContour.lowerLipBottom;
      case mlkit.FaceContourType.noseBridge:
        return FaceContour.noseBridge;
      case mlkit.FaceContourType.noseBottom:
        return FaceContour.noseBottom;
      case mlkit.FaceContourType.leftCheek:
      case mlkit.FaceContourType.rightCheek:
        // Cheek contours are single-point "blob" estimates, not
        // true outlines. Phase 9f ignores them; a future cheek-lift
        // feature can promote them when it needs them.
        return null;
    }
  }
}

/// Typed error for face detection failures. Distinguish from
/// inference exceptions in the bg-removal layer — face detection is
/// its own pipeline and its own log prefix.
///
/// [cause] carries the underlying exception (usually the ML Kit
/// platform error) when this was rewrapped from another type so
/// session-level logs keep the full failure chain. Matches the
/// `BgRemovalException.cause` pattern from the 9c audit.
class FaceDetectionException implements Exception {
  const FaceDetectionException(this.message, {this.cause});
  final String message;
  final Object? cause;

  @override
  String toString() {
    if (cause == null) return 'FaceDetectionException: $message';
    return 'FaceDetectionException: $message (caused by $cause)';
  }
}

/// Alias used by the mask builder so the `dart:math.Point` import
/// isn't leaked into public APIs.
typedef FacePoint = Point<double>;
