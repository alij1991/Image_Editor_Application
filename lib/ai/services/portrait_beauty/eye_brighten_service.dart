import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import '../../../core/logging/app_logger.dart';
import '../../inference/polygon_mask_builder.dart';
import '../face_mesh/face_mesh_service.dart';
import '../../inference/landmark_mask_builder.dart';
import '../../inference/mask_stats.dart';
import '../../inference/rgb_ops.dart';
import '../../inference/rgba_compositor.dart';
import '../bg_removal/image_io.dart';
import '../face_detect/face_detection_service.dart';

final _log = AppLogger('EyeBrightenService');

/// Phase 9e eye-brightening pipeline.
///
/// Detects every face in the source image, stamps a soft circle at
/// each left/right eye landmark (the radius scales with the
/// inter-eye distance so close-ups and full-body shots hit
/// proportional targets), then composites a brightened copy of the
/// source back onto the original through that mask.
///
/// Output: a `ui.Image` the caller stores in an [AdjustmentLayer]
/// with `kind == AdjustmentKind.eyeBrighten`. The layer renders on
/// top of the preview via the existing adjustment-layer paint path.
///
/// Throws [EyeBrightenException] for anything from "no face detected"
/// to "IO failure decoding source" — each message is user-readable
/// so the editor page can put it straight into a snackbar.
class EyeBrightenService {
  EyeBrightenService({
    required this.detector,
    this.faceMesh,
    this.brightness = 1.25,
    this.eyeRadiusFraction = 0.15,
    this.minRadius = 4,
    this.maxRadius = 60,
    this.feather = 0.5,
  }) {
    _log.i('created', {
      'brightness': brightness,
      'eyeRadiusFraction': eyeRadiusFraction,
      'minRadius': minRadius,
      'maxRadius': maxRadius,
      'feather': feather,
      'faceMesh': faceMesh != null,
    });
  }

  /// The face detector, owned by the caller.
  final FaceDetectionService detector;

  /// Optional MediaPipe Face Mesh — when present, the brightening
  /// mask is the precise 16-point eye-ring polygon per eye instead of
  /// a disc around the eye landmark. Captures the sclera + iris
  /// without leaking onto eyelids or lashes.
  final FaceMeshService? faceMesh;

  /// RGB multiplier applied inside the eye mask. `1.0` is a no-op;
  /// defaults to `1.25` for a subtle "awake" lift.
  final double brightness;

  /// Eye circle radius as a fraction of the inter-eye distance.
  /// Default `0.15` keeps the circle confined to the eyeball area
  /// without lighting up the eyelid or brow.
  final double eyeRadiusFraction;

  /// Clamp on the computed radius so tiny faces still get a
  /// visible effect and huge close-ups don't flood the frame.
  final int minRadius;
  final int maxRadius;

  /// Feather passed through to [LandmarkMaskBuilder.build]. `0.5`
  /// gives a soft but still anchored edge.
  final double feather;

  bool _closed = false;

  /// Phase V.1: callers that already have a detection result (the
  /// editor session's per-source cache) can pass [preloadedFaces] to
  /// skip the internal `detector.detectFromPath` call entirely.
  /// Standalone callers omit it; the service runs detection itself.
  Future<ui.Image> brightenFromPath(
    String sourcePath, {
    List<DetectedFace>? preloadedFaces,
  }) async {
    if (_closed) {
      _log.w('run rejected — service closed', {'path': sourcePath});
      throw const EyeBrightenException('EyeBrightenService is closed');
    }
    final total = Stopwatch()..start();
    _log.i('run start',
        {'path': sourcePath, 'preloadedFaces': preloadedFaces != null});

    // 1. Detect faces + collect eye points — or reuse the preloaded
    //    result when the session already has one cached.
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
        throw EyeBrightenException(
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
      throw const EyeBrightenException(
        'No face detected. Make sure the eyes are visible and the '
        'subject is facing the camera.',
      );
    }

    try {
      // 2. Decode source first to compute the coordinate-space ratio.
      //    Preview-quality decode keeps the output layer bigger than
      //    the preview so no upscaling softness on top of the effect.
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

      // 3. Build eye mask. Prefer the Face Mesh per-eye polygon when
      //    available (captures sclera + iris precisely); fall back to
      //    the legacy disc around the eye landmark when the mesh
      //    model isn't loaded or inference fails.
      final maskSw = Stopwatch()..start();
      Float32List? mask;
      if (faceMesh != null && scaledFaces.isNotEmpty) {
        mask = await _tryBuildMeshMask(
          faceMesh: faceMesh!,
          decoded: decoded,
          face: scaledFaces.first,
        );
      }
      if (mask == null) {
        final spots = _buildSpotsFromFaces(scaledFaces);
        _log.d('spots (legacy disc mask)', {'count': spots.length});
        if (spots.isEmpty) {
          total.stop();
          _log.w('no eye landmarks', {
            'ms': total.elapsedMilliseconds,
            'faces': scaledFaces.length,
          });
          throw const EyeBrightenException(
            "Couldn't find eye landmarks. Try a sharper photo with "
            'the subject facing the camera.',
          );
        }
        mask = LandmarkMaskBuilder.build(
          spots: spots,
          width: decoded.width,
          height: decoded.height,
          feather: feather,
        );
      }
      maskSw.stop();
      final maskStatsValue = MaskStats.compute(mask);
      _log.d('mask built', {
        'ms': maskSw.elapsedMilliseconds,
        ...maskStatsValue.toLogMap(),
      });
      if (maskStatsValue.isEffectivelyEmpty) {
        _log.w(
            'eye mask is empty — landmarks may be outside image bounds',
            maskStatsValue.toLogMap());
        throw const EyeBrightenException(
          "Couldn't apply the effect — eye landmarks fell outside "
          'the image bounds. Try reframing the photo.',
        );
      }

      // 4. Brighten a full copy of the source.
      final opSw = Stopwatch()..start();
      final brightened = RgbOps.brightenRgb(
        source: decoded.bytes,
        width: decoded.width,
        height: decoded.height,
        factor: brightness,
      );
      opSw.stop();
      _log.d('brighten', {
        'ms': opSw.elapsedMilliseconds,
        'factor': brightness,
      });

      // 5. Composite via the eye mask.
      final compSw = Stopwatch()..start();
      final result = compositeOverlayRgba(
        base: decoded.bytes,
        overlay: brightened,
        mask: mask,
        width: decoded.width,
        height: decoded.height,
      );
      compSw.stop();
      _log.d('composite', {'ms': compSw.elapsedMilliseconds});

      // 6. Re-upload as a ui.Image.
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
        'brightenMs': opSw.elapsedMilliseconds,
        'compositeMs': compSw.elapsedMilliseconds,
        'outputW': image.width,
        'outputH': image.height,
        'faces': scaledFaces.length,
      });
      return image;
    } on EyeBrightenException {
      rethrow;
    } on BgRemovalIoException catch (e) {
      total.stop();
      _log.w('run IO failure — rewrapping', {
        'message': e.message,
        'ms': total.elapsedMilliseconds,
      });
      throw EyeBrightenException(e.message, cause: e);
    } catch (e, st) {
      total.stop();
      _log.e('run failed',
          error: e,
          stackTrace: st,
          data: {'ms': total.elapsedMilliseconds});
      throw EyeBrightenException(e.toString(), cause: e);
    }
  }

  /// Run Face Mesh and build the union of left-eye + right-eye
  /// polygon stamps. Returns null on any failure — the caller falls
  /// back to the disc-around-landmark mask in that case.
  Future<Float32List?> _tryBuildMeshMask({
    required FaceMeshService faceMesh,
    required DecodedRgba decoded,
    required DetectedFace face,
  }) async {
    try {
      final result = await faceMesh.runOnRgba(
        sourceRgba: decoded.bytes,
        sourceWidth: decoded.width,
        sourceHeight: decoded.height,
        faceBoundingBox: face.boundingBox,
      );
      if (result == null) return null;
      final mask = Float32List(decoded.width * decoded.height);
      PolygonMaskBuilder.stampInto(
        target: mask,
        polygon: [
          for (final i in FaceMeshIndices.leftEye) result.landmarks[i],
        ],
        width: decoded.width,
        height: decoded.height,
        featherRadius: 2,
      );
      PolygonMaskBuilder.stampInto(
        target: mask,
        polygon: [
          for (final i in FaceMeshIndices.rightEye) result.landmarks[i],
        ],
        width: decoded.width,
        height: decoded.height,
        featherRadius: 2,
      );
      return mask;
    } catch (e, st) {
      _log.w('face mesh failed — falling back to legacy mask', {
        'error': e.toString(),
        'stack': st.toString().split('\n').first,
      });
      return null;
    }
  }

  /// Build one circle spot per eye landmark. Radius is a function
  /// of the per-face inter-eye distance so close-ups and full-body
  /// shots land proportional eye regions.
  List<LandmarkSpot> _buildSpotsFromFaces(List<DetectedFace> faces) {
    final spots = <LandmarkSpot>[];
    for (final face in faces) {
      final left = face.landmarks[FaceLandmark.leftEye];
      final right = face.landmarks[FaceLandmark.rightEye];
      if (left == null && right == null) continue;
      final double eyeDist;
      if (left != null && right != null) {
        eyeDist = (left - right).distance;
      } else {
        // Fallback: use the face bounding-box width if only one
        // eye was detected.
        eyeDist = face.boundingBox.width * 0.4;
      }
      final raw = (eyeDist * eyeRadiusFraction).round();
      final radius = raw.clamp(minRadius, maxRadius).toDouble();
      if (left != null) {
        spots.add(LandmarkSpot(center: left, radius: radius));
      }
      if (right != null) {
        spots.add(LandmarkSpot(center: right, radius: radius));
      }
    }
    return spots;
  }

  /// Mark closed. Does NOT close the shared [detector] — the caller
  /// owns that lifecycle.
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _log.i('close');
  }
}

/// Typed exception surface for eye-brightening failures. Messages
/// are user-facing so the editor page can show them verbatim.
///
/// [cause] carries the underlying exception when this was rewrapped
/// so session logs retain the full chain.
class EyeBrightenException implements Exception {
  const EyeBrightenException(this.message, {this.cause});
  final String message;
  final Object? cause;

  @override
  String toString() {
    if (cause == null) return 'EyeBrightenException: $message';
    return 'EyeBrightenException: $message (caused by $cause)';
  }
}
