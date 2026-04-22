import 'dart:math' as math;
import 'dart:ui' as ui;

import '../../../core/logging/app_logger.dart';
import '../../inference/image_warper.dart';
import '../bg_removal/image_io.dart';
import '../face_detect/face_detection_service.dart';

final _log = AppLogger('FaceReshapeService');

/// Phase 9f face reshape pipeline.
///
/// Detects face contours via ML Kit (no extra model download —
/// contours come from the same on-device face detector Phase 9d
/// already uses, just with `enableContours: true`), derives a set
/// of [WarpAnchor]s that encode the reshape semantics (slim face,
/// enlarge eyes), and runs [ImageWarper] to produce a reshaped
/// `ui.Image` the editor stores in an [AdjustmentLayer].
///
/// Unlike the Phase 9d/9e services, the output is NOT composited
/// over the original via a mask — it's a full-frame warp of every
/// pixel, because the reshape needs to continuously displace
/// neighborhoods rather than blend one region over another. That
/// means face reshape DOES shift background pixels near the face
/// contour, which is visually subtle with the default parameters
/// but will become visible at larger strengths. Slated for a more
/// careful mask-confined variant in a future pass.
///
/// Throws [FaceReshapeException] with user-facing messages for
/// every failure mode so the editor page can snackbar them
/// verbatim.
class FaceReshapeService {
  FaceReshapeService({
    required this.detector,
    this.slimFaceStrength = 0.3,
    this.enlargeEyesStrength = 0.15,
    this.anchorRadiusFraction = 0.12,
  }) {
    // Log tuning params at construction so post-hoc triage can
    // correlate user-reported artifacts to the exact values the
    // service ran with. Matches the 9d/9e service pattern.
    _log.i('created', {
      'slimFaceStrength': slimFaceStrength,
      'enlargeEyesStrength': enlargeEyesStrength,
      'anchorRadiusFraction': anchorRadiusFraction,
    });
  }

  /// The face detector, owned by the caller. Must have been built
  /// with `enableContours: true` — this service throws at the
  /// start of [reshapeFromPath] if the detector returned no
  /// contour data, which is almost always a "you forgot to enable
  /// contours" bug.
  final FaceDetectionService detector;

  /// How aggressively to pull face-outline points inward toward
  /// the face center. `0.0` = no slimming; `1.0` = pull points to
  /// ~5% of face width inward. Keep small (≤ 0.5) — larger values
  /// make the background warp visible.
  final double slimFaceStrength;

  /// How aggressively to push eye-outline points outward from the
  /// eye center. `0.0` = no change; `1.0` = push ~10% of eye
  /// radius outward.
  final double enlargeEyesStrength;

  /// Warp anchor radius as a fraction of the face bounding box
  /// width. Default `0.12` keeps the radius tight enough that
  /// anchors on opposite sides of the face don't overlap.
  final double anchorRadiusFraction;

  bool _closed = false;

  /// Run the pipeline on the image at [sourcePath] and return a
  /// new `ui.Image` whose face has been subtly reshaped.
  ///
  /// Throws [FaceReshapeException] on failure. The message text is
  /// user-facing — the editor page shows it verbatim.
  ///
  /// Phase V.1: callers that already have a detection result (the
  /// editor session's per-source cache) can pass [preloadedFaces]
  /// to skip the internal `detector.detectFromPath` call. The
  /// preloaded faces must carry contour data (i.e. they came from a
  /// detector built with `enableContours: true`) — otherwise the
  /// downstream anchor builder will find no contour points and
  /// raise the "couldn't find enough face contour points" error.
  Future<ui.Image> reshapeFromPath(
    String sourcePath, {
    List<DetectedFace>? preloadedFaces,
  }) async {
    if (_closed) {
      _log.w('run rejected — service closed', {'path': sourcePath});
      throw const FaceReshapeException('FaceReshapeService is closed');
    }
    if (!detector.enableContours) {
      _log.w('detector was not built with enableContours: true');
      throw const FaceReshapeException(
        'Internal error: face reshape needs a contour-enabled '
        'detector. Please retry.',
      );
    }
    final total = Stopwatch()..start();
    _log.i('run start',
        {'path': sourcePath, 'preloadedFaces': preloadedFaces != null});

    // 1. Detect faces + contours — or reuse the preloaded result
    //    when the session already has one cached.
    final detectSw = Stopwatch()..start();
    final List<DetectedFace> faces;
    if (preloadedFaces != null) {
      faces = preloadedFaces;
      _log.d('using preloaded faces', {'count': faces.length});
    } else {
      try {
        faces = await detector.detectFromPath(sourcePath);
      } on FaceDetectionException catch (e) {
        total.stop();
        _log.w('detector failed — rewrapping', {
          'message': e.message,
          'ms': total.elapsedMilliseconds,
        });
        throw FaceReshapeException(
          'Face detection failed: ${e.message}',
          cause: e,
        );
      }
    }
    detectSw.stop();
    _log.d('detection', {
      'ms': detectSw.elapsedMilliseconds,
      'count': faces.length,
      'preloaded': preloadedFaces != null,
    });
    if (faces.isEmpty) {
      total.stop();
      _log.w('no face detected', {'ms': total.elapsedMilliseconds});
      throw const FaceReshapeException(
        'No face detected. Make sure the subject is facing the '
        'camera and the face is clearly visible.',
      );
    }

    try {
      // 2. Decode source first to know the target resolution so we can
      //    scale face coordinates from detection space (max 1536 px) to
      //    service decode space. Uses preview-quality dimension (2 048)
      //    so the warped layer renders without upscaling softness.
      final decoded = await BgRemovalImageIo.decodeFileToRgba(
        sourcePath,
        maxDimension: BgRemovalImageIo.previewQualityDecodeDimension,
      );
      _log.d('source decoded', {
        'path': sourcePath,
        'w': decoded.width,
        'h': decoded.height,
      });

      final origLongest = math.max(
          decoded.originalWidth, decoded.originalHeight);
      final detectLongest = math.min(
          origLongest, FaceDetectionService.kMaxDetectDimension);
      final decodedLongest = math.max(decoded.width, decoded.height);
      final coordScale = detectLongest > 0
          ? decodedLongest / detectLongest
          : 1.0;
      final scaledFaces = coordScale == 1.0
          ? faces
          : faces.map((f) => f.scaled(coordScale)).toList();

      // 3. Build warp anchors from every face's contours (in decoded space).
      final anchorsSw = Stopwatch()..start();
      final anchors = <WarpAnchor>[];
      int slimCount = 0;
      int eyeCount = 0;
      for (final face in scaledFaces) {
        final slim = _slimFaceAnchorsFor(face);
        final eye = _enlargeEyesAnchorsFor(face);
        anchors.addAll(slim);
        anchors.addAll(eye);
        slimCount += slim.length;
        eyeCount += eye.length;
      }
      anchorsSw.stop();
      _log.d('anchors built', {
        'ms': anchorsSw.elapsedMilliseconds,
        'count': anchors.length,
        'slimFace': slimCount,
        'enlargeEyes': eyeCount,
        'faces': scaledFaces.length,
      });
      if (anchors.isEmpty) {
        total.stop();
        _log.w('no anchors — contours missing or reshape strengths are all zero',
            {'ms': total.elapsedMilliseconds});
        throw const FaceReshapeException(
          "Couldn't find enough face contour points to reshape. "
          'Try a clearer photo where the face is well-lit.',
        );
      }

      // 4. Apply the warp.
      final warpSw = Stopwatch()..start();
      final warped = ImageWarper.apply(
        source: decoded.bytes,
        width: decoded.width,
        height: decoded.height,
        anchors: anchors,
      );
      warpSw.stop();
      _log.d('warp', {'ms': warpSw.elapsedMilliseconds});

      // 5. Re-upload as a ui.Image.
      final image = await BgRemovalImageIo.encodeRgbaToUiImage(
        rgba: warped,
        width: decoded.width,
        height: decoded.height,
      );
      total.stop();
      _log.i('run complete', {
        'totalMs': total.elapsedMilliseconds,
        'detectMs': detectSw.elapsedMilliseconds,
        'anchorsMs': anchorsSw.elapsedMilliseconds,
        'warpMs': warpSw.elapsedMilliseconds,
        'outputW': image.width,
        'outputH': image.height,
        'anchors': anchors.length,
        'slimFace': slimCount,
        'enlargeEyes': eyeCount,
        'faces': faces.length,
      });
      return image;
    } on FaceReshapeException {
      rethrow;
    } on BgRemovalIoException catch (e) {
      total.stop();
      _log.w('run IO failure — rewrapping', {
        'message': e.message,
        'ms': total.elapsedMilliseconds,
      });
      throw FaceReshapeException(e.message, cause: e);
    } catch (e, st) {
      total.stop();
      _log.e('run failed',
          error: e,
          stackTrace: st,
          data: {'ms': total.elapsedMilliseconds});
      throw FaceReshapeException(e.toString(), cause: e);
    }
  }

  /// Mark this service as closed. Does NOT close the shared
  /// [detector] — the caller owns its lifecycle.
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _log.i('close');
  }

  // ----- anchor builders --------------------------------------------------

  /// For each face-outline contour point, pull inward toward the
  /// face center by `slimFaceStrength * faceWidth * 0.05`. The
  /// 0.05 hard cap keeps the default (`strength = 0.3`) visible
  /// but subtle; larger strengths push into unsafe territory.
  List<WarpAnchor> _slimFaceAnchorsFor(DetectedFace face) {
    if (slimFaceStrength <= 0) return const [];
    final outline = face.contours[FaceContour.face];
    if (outline == null || outline.isEmpty) return const [];
    final center = face.boundingBox.center;
    final faceWidth = face.boundingBox.width;
    final pullMagnitude = slimFaceStrength * faceWidth * 0.05;
    final radius = faceWidth * anchorRadiusFraction;
    final out = <WarpAnchor>[];
    for (final p in outline) {
      final vec = center - p;
      final len = vec.distance;
      if (len < 1e-6) continue;
      final unit = vec / len;
      final target = p + unit * pullMagnitude;
      out.add(WarpAnchor(source: p, target: target, radius: radius));
    }
    return out;
  }

  /// For each eye-outline contour point, push outward from the
  /// eye center by `enlargeEyesStrength * eyeRadius * 0.1`.
  /// Applies to both eyes independently.
  List<WarpAnchor> _enlargeEyesAnchorsFor(DetectedFace face) {
    if (enlargeEyesStrength <= 0) return const [];
    final out = <WarpAnchor>[];
    for (final key in const [FaceContour.leftEye, FaceContour.rightEye]) {
      final loop = face.contours[key];
      if (loop == null || loop.isEmpty) continue;
      // Estimate eye center as the centroid of its contour loop.
      double sumX = 0;
      double sumY = 0;
      for (final p in loop) {
        sumX += p.dx;
        sumY += p.dy;
      }
      final eyeCenter = ui.Offset(sumX / loop.length, sumY / loop.length);
      // Estimate eye radius as the mean distance from center to
      // each contour point.
      double sumR = 0;
      for (final p in loop) {
        sumR += (p - eyeCenter).distance;
      }
      final eyeRadius = sumR / loop.length;
      if (eyeRadius < 1) continue;
      final pushMagnitude = enlargeEyesStrength * eyeRadius * 0.1;
      // Anchor radius scales with eye size so small faces don't
      // get oversized influence zones.
      final radius = eyeRadius * 2.0;
      for (final p in loop) {
        final vec = p - eyeCenter;
        final len = vec.distance;
        if (len < 1e-6) continue;
        final unit = vec / len;
        final target = p + unit * pushMagnitude;
        out.add(WarpAnchor(source: p, target: target, radius: radius));
      }
    }
    return out;
  }
}

/// Typed exception surface for face reshape failures. Messages are
/// user-facing so the editor page can show them verbatim.
///
/// [cause] carries the underlying exception when this was rewrapped
/// (face detection failed, IO decode failed, etc.) so session logs
/// retain the original stack trace — matches the post-9c-audit
/// pattern used by every other AI service.
class FaceReshapeException implements Exception {
  const FaceReshapeException(this.message, {this.cause});
  final String message;
  final Object? cause;

  @override
  String toString() {
    if (cause == null) return 'FaceReshapeException: $message';
    return 'FaceReshapeException: $message (caused by $cause)';
  }
}
