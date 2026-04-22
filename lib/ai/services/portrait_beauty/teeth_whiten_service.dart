import 'dart:math' as math;
import 'dart:ui' as ui;

import '../../../core/logging/app_logger.dart';
import '../../inference/landmark_mask_builder.dart';
import '../../inference/mask_stats.dart';
import '../../inference/rgb_ops.dart';
import '../../inference/rgba_compositor.dart';
import '../bg_removal/image_io.dart';
import '../face_detect/face_detection_service.dart';

final _log = AppLogger('TeethWhitenService');

/// Phase 9e teeth-whitening pipeline.
///
/// Detects faces, averages the left/right/bottom mouth landmarks
/// into a mouth center, stamps a feathered circle at that point
/// with a radius derived from the left-to-right mouth distance,
/// desaturates + brightens a copy of the source (our stand-in for
/// a proper LAB whitening), and composites it back onto the
/// original through the mouth mask.
///
/// Trade-offs vs. a "real" teeth whitener:
///
/// - We don't carve the lips out — the mouth mask is intentionally
///   small and the desaturate strength + brightness multiplier are
///   conservative so lip color shifts stay minimal. A future pass
///   can classify pixels inside the mask as "tooth-like" using a
///   luminance + saturation heuristic and only adjust those.
/// - No face mesh, so we rely on the bundled ML Kit detector's
///   three mouth points. Enough for a Phase 9e starting point; face
///   mesh comes with the reshape sub-phase.
///
/// Throws [TeethWhitenException] with a user-readable message for
/// every failure mode so the editor page can snackbar it verbatim.
class TeethWhitenService {
  TeethWhitenService({
    required this.detector,
    this.desaturate = 0.4,
    this.brightness = 1.08,
    this.mouthRadiusFraction = 0.42,
    this.minRadius = 5,
    this.maxRadius = 70,
    this.feather = 0.6,
  }) {
    _log.i('created', {
      'desaturate': desaturate,
      'brightness': brightness,
      'mouthRadiusFraction': mouthRadiusFraction,
      'minRadius': minRadius,
      'maxRadius': maxRadius,
      'feather': feather,
    });
  }

  /// The face detector, owned by the caller.
  final FaceDetectionService detector;

  /// Fraction of saturation removed inside the mouth mask (`0`=no
  /// change, `1`=fully greyscale).
  final double desaturate;

  /// RGB brightness multiplier applied after desaturation.
  final double brightness;

  /// Mouth circle radius as a fraction of the left-to-right mouth
  /// distance. Default `0.42` = a circle about as wide as the
  /// mouth itself, roughly centered on the teeth region.
  final double mouthRadiusFraction;

  /// Clamp on the computed radius so tiny faces still get a visible
  /// effect and huge close-ups don't drift onto the chin.
  final int minRadius;
  final int maxRadius;

  /// Feather passed through to [LandmarkMaskBuilder.build]. Bigger
  /// than the eye feather because the mouth mask is bigger and
  /// needs a softer edge to hide on the lips.
  final double feather;

  bool _closed = false;

  /// Phase V.1: callers that already have a detection result (the
  /// editor session's per-source cache) can pass [preloadedFaces] to
  /// skip the internal `detector.detectFromPath` call entirely.
  /// Standalone callers omit it; the service runs detection itself.
  Future<ui.Image> whitenFromPath(
    String sourcePath, {
    List<DetectedFace>? preloadedFaces,
  }) async {
    if (_closed) {
      _log.w('run rejected — service closed', {'path': sourcePath});
      throw const TeethWhitenException('TeethWhitenService is closed');
    }
    final total = Stopwatch()..start();
    _log.i('run start',
        {'path': sourcePath, 'preloadedFaces': preloadedFaces != null});

    // 1. Detect faces — or reuse the preloaded result when the
    //    session already has one cached.
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
        throw TeethWhitenException(
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
      throw const TeethWhitenException(
        'No face detected. Make sure the mouth is visible and the '
        'subject is facing the camera.',
      );
    }

    try {
      // 2. Decode source first so we can compute the coordinate-space
      //    ratio between detection resolution (max 1536 px) and decode
      //    resolution (max 1024 px) before building mouth spots.
      final decoded = await BgRemovalImageIo.decodeFileToRgba(sourcePath);
      _log.d('source decoded', {
        'path': sourcePath,
        'w': decoded.width,
        'h': decoded.height,
      });

      // Scale face coordinates from detection space to service decode space.
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

      // 3. Build one mouth spot per face, skipping faces without
      //    mouth landmarks. Uses scaled coordinates so the mask lands
      //    on the correct pixels in the decoded image.
      final spots = _buildSpotsFromFaces(scaledFaces);
      _log.d('spots', {'count': spots.length});
      if (spots.isEmpty) {
        total.stop();
        _log.w('no mouth landmarks', {
          'ms': total.elapsedMilliseconds,
          'faces': scaledFaces.length,
        });
        throw const TeethWhitenException(
          "Couldn't find mouth landmarks. Try a sharper photo where "
          "the subject's mouth is clearly visible.",
        );
      }

      // 4. Build mouth mask.
      final maskSw = Stopwatch()..start();
      final mask = LandmarkMaskBuilder.build(
        spots: spots,
        width: decoded.width,
        height: decoded.height,
        feather: feather,
      );
      maskSw.stop();
      final maskStatsValue = MaskStats.compute(mask);
      _log.d('mask built', {
        'ms': maskSw.elapsedMilliseconds,
        ...maskStatsValue.toLogMap(),
      });
      if (maskStatsValue.isEffectivelyEmpty) {
        _log.w(
            'mouth mask is empty — landmarks may be outside image bounds',
            maskStatsValue.toLogMap());
        throw const TeethWhitenException(
          "Couldn't apply the effect — mouth landmarks fell outside "
          'the image bounds. Try reframing the photo.',
        );
      }

      // 5. Whiten a full copy of the source.
      final opSw = Stopwatch()..start();
      final whitened = RgbOps.whitenRgb(
        source: decoded.bytes,
        width: decoded.width,
        height: decoded.height,
        desaturate: desaturate,
        brightness: brightness,
      );
      opSw.stop();
      _log.d('whiten', {
        'ms': opSw.elapsedMilliseconds,
        'desaturate': desaturate,
        'brightness': brightness,
      });

      // 6. Composite via the mouth mask.
      final compSw = Stopwatch()..start();
      final result = compositeOverlayRgba(
        base: decoded.bytes,
        overlay: whitened,
        mask: mask,
        width: decoded.width,
        height: decoded.height,
      );
      compSw.stop();
      _log.d('composite', {'ms': compSw.elapsedMilliseconds});

      // 7. Re-upload as a ui.Image.
      final image = await BgRemovalImageIo.encodeRgbaToUiImage(
        rgba: result,
        width: decoded.width,
        height: decoded.height,
      );
      total.stop();
      _log.i('run complete', {
        'totalMs': total.elapsedMilliseconds,
        'detectMs': detectSw.elapsedMilliseconds,
        'maskMs': maskSw.elapsedMilliseconds,
        'whitenMs': opSw.elapsedMilliseconds,
        'compositeMs': compSw.elapsedMilliseconds,
        'outputW': image.width,
        'outputH': image.height,
        'spots': spots.length,
      });
      return image;
    } on TeethWhitenException {
      rethrow;
    } on BgRemovalIoException catch (e) {
      total.stop();
      _log.w('run IO failure — rewrapping', {
        'message': e.message,
        'ms': total.elapsedMilliseconds,
      });
      throw TeethWhitenException(e.message, cause: e);
    } catch (e, st) {
      total.stop();
      _log.e('run failed',
          error: e,
          stackTrace: st,
          data: {'ms': total.elapsedMilliseconds});
      throw TeethWhitenException(e.toString(), cause: e);
    }
  }

  List<LandmarkSpot> _buildSpotsFromFaces(List<DetectedFace> faces) {
    final spots = <LandmarkSpot>[];
    for (final face in faces) {
      final left = face.landmarks[FaceLandmark.leftMouth];
      final right = face.landmarks[FaceLandmark.rightMouth];
      final bottom = face.landmarks[FaceLandmark.bottomMouth];
      if (left == null && right == null && bottom == null) continue;

      // Average the available mouth points for the center.
      double sumX = 0;
      double sumY = 0;
      int n = 0;
      for (final p in [left, right, bottom]) {
        if (p == null) continue;
        sumX += p.dx;
        sumY += p.dy;
        n++;
      }
      final center = ui.Offset(sumX / n, sumY / n);

      // Radius scales with mouth width if both corners are present;
      // fallback to a quarter of the face width.
      final double mouthWidth;
      if (left != null && right != null) {
        mouthWidth = (left - right).distance;
      } else {
        mouthWidth = face.boundingBox.width * 0.25;
      }
      final raw = (mouthWidth * mouthRadiusFraction).round();
      final radius = raw.clamp(minRadius, maxRadius).toDouble();
      spots.add(LandmarkSpot(center: center, radius: radius));
    }
    return spots;
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _log.i('close');
  }
}

/// Typed exception surface for teeth-whitening failures. Message
/// text is user-facing.
///
/// [cause] carries the underlying exception when this was rewrapped
/// so session logs retain the full chain.
class TeethWhitenException implements Exception {
  const TeethWhitenException(this.message, {this.cause});
  final String message;
  final Object? cause;

  @override
  String toString() {
    if (cause == null) return 'TeethWhitenException: $message';
    return 'TeethWhitenException: $message (caused by $cause)';
  }
}
