import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import '../../../core/logging/app_logger.dart';
import '../../inference/edge_preserving_blur.dart';
import '../../inference/face_mask_builder.dart';
import '../../inference/mask_stats.dart';
import '../../inference/polygon_mask_builder.dart';
import '../../inference/rgba_compositor.dart';
import '../bg_removal/image_io.dart';
import '../face_detect/face_detection_service.dart';
import '../face_mesh/face_mesh_service.dart';

final _log = AppLogger('PortraitSmoothService');

/// Phase 9d skin-smoothing pipeline.
///
/// Runs face detection on the source image, carves a feathered mask
/// around each detected face (with eye + mouth exclusion zones),
/// blurs a copy of the image with a box blur whose radius scales
/// with face size, and composites the blurred version back onto the
/// original using the face mask as an alpha weight.
///
/// Returns a `ui.Image` that the caller stores inside an
/// [AdjustmentLayer] with `kind == portraitSmooth`. The layer then
/// renders on top of the preview via the existing adjustment-layer
/// paint path.
///
/// **Why a service instead of a strategy hierarchy?** Phase 9d ships
/// a single implementation. When Phase 9e/9f add more beauty
/// strategies (e.g. GPU-accelerated bilateral, ML-matted
/// body-segmented smoothing) we'll promote this to a
/// `PortraitBeautyStrategy` enum + factory the same way Phase 9c
/// did for bg removal. Until then, keeping it concrete avoids
/// boilerplate + premature abstraction.
class PortraitSmoothService {
  PortraitSmoothService({
    required this.detector,
    this.faceMesh,
    this.featherFraction = 0.35,
    this.blurRadiusFraction = 0.03,
    this.minBlurRadius = 3,
    this.maxBlurRadius = 18,
    this.edgeThreshold = 0.08,
    this.detailRestoration = 0.30,
  }) {
    // Log tuning parameters at construction so post-hoc bug triage
    // can correlate a user-visible artifact to the exact values the
    // service was configured with (defaults today, but any future
    // call-site override will show up in the trace).
    _log.i('created', {
      'featherFraction': featherFraction,
      'blurRadiusFraction': blurRadiusFraction,
      'minBlurRadius': minBlurRadius,
      'maxBlurRadius': maxBlurRadius,
      'edgeThreshold': edgeThreshold,
      'detailRestoration': detailRestoration,
    });
  }

  /// The face detector to run at apply time. Ownership stays with
  /// the caller; [close] does NOT close the detector so the caller
  /// can reuse it across invocations.
  final FaceDetectionService detector;

  /// Optional MediaPipe Face Mesh. When set, the skin mask is the
  /// face-oval polygon with eye rings + brows + inner-lip rings
  /// subtracted, giving a precise "skin-only" target. Null callers
  /// fall back to the feathered-ellipse mask.
  final FaceMeshService? faceMesh;

  /// Feather fraction passed through to [FaceMaskBuilder.build].
  /// Bigger = softer face-edge transition.
  final double featherFraction;

  /// Box-blur radius as a fraction of the face bounding-box width.
  /// Larger faces get larger blur → perceived smoothing stays
  /// consistent across portrait and full-body shots.
  final double blurRadiusFraction;

  /// Absolute lower / upper bounds for the computed blur radius so
  /// tiny background faces aren't obliterated and huge close-ups
  /// don't eat the whole frame.
  final int minBlurRadius;
  final int maxBlurRadius;

  /// Edge-preservation threshold for [EdgePreservingBlur]. Pixels
  /// whose local luminance differential exceeds this fraction
  /// (of 255) are treated as edges and kept from the source instead
  /// of being blurred — keeps eyes / lip lines / brow hairs crisp.
  final double edgeThreshold;

  /// Fraction of the original micro-texture to mix back into the
  /// smoothed output after the bilateral pass. `0.0` = fully
  /// smoothed (can look plastic on skin); `0.3` is the default for
  /// a smooth-but-alive portrait; `1.0` = no smoothing at all.
  final double detailRestoration;

  bool _closed = false;

  /// Run the full pipeline on the image at [sourcePath] and return a
  /// new `ui.Image` whose face regions have been softened in place.
  ///
  /// Throws [PortraitSmoothException] on failure — the caller can
  /// show a typed error snackbar. Specifically throws the "no face
  /// detected" variant so the UI can coach the user ("make sure the
  /// subject's face is in frame").
  ///
  /// Phase V.1: callers that already have a detection result (the
  /// editor session's per-source cache) can pass [preloadedFaces] to
  /// skip the internal `detector.detectFromPath` call entirely.
  /// Standalone callers omit it; the service runs detection itself,
  /// preserving backward compatibility.
  Future<ui.Image> smoothFromPath(
    String sourcePath, {
    List<DetectedFace>? preloadedFaces,
  }) async {
    if (_closed) {
      _log.w('run rejected — service closed', {'path': sourcePath});
      throw const PortraitSmoothException(
          'PortraitSmoothService is closed');
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
        throw PortraitSmoothException(
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
      throw const PortraitSmoothException(
        'No face detected. Try another photo or move the subject '
        'closer to the camera.',
      );
    }

    try {
      // 2. Decode source image into raw RGBA at preview-quality
      //    resolution so the rendered layer doesn't need upscaling
      //    (which would visibly soften the result on top of the
      //    intentional blur).
      final decoded = await BgRemovalImageIo.decodeFileToRgba(
        sourcePath,
        maxDimension: BgRemovalImageIo.previewQualityDecodeDimension,
      );
      _log.d('source decoded', {
        'path': sourcePath,
        'w': decoded.width,
        'h': decoded.height,
      });

      // 3. Scale face coordinates from detection space (max
      //    kMaxDetectDimension px) to service decode space (max 1024 px).
      //    Without this scaling, the mask ellipse lands at the wrong
      //    pixel location on large-sensor photos (e.g. 24 MP where
      //    detection runs at 1536 px but the service decodes to 1024 px).
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

      // 4. Build the face mask. Prefer the Face Mesh skin polygon
      //    (face oval minus eyes/brows/lips) when available — it
      //    lands only on actual skin pixels so brow hairs, lip
      //    detail and eye lashes never get smoothed. Fall back to
      //    the feathered-ellipse + soft-subtract builder otherwise.
      final maskSw = Stopwatch()..start();
      Float32List? mask;
      if (faceMesh != null && scaledFaces.isNotEmpty) {
        mask = await _tryBuildMeshMask(
          faceMesh: faceMesh!,
          decoded: decoded,
          face: scaledFaces.first,
        );
      }
      mask ??= FaceMaskBuilder.build(
        faces: scaledFaces,
        width: decoded.width,
        height: decoded.height,
        feather: featherFraction,
      );
      maskSw.stop();
      // Mask stats give us an early-warning signal if the face
      // detector returned boxes outside the image, or if the
      // feather values are too aggressive. Bail out before we
      // spend ~400ms blurring + compositing a result that would
      // be visually identical to the source (matching
      // EyeBrightenService and TeethWhitenService — every beauty
      // service in the suite treats "empty mask" as a user-visible
      // failure, not a silent no-op).
      final maskStatsValue = MaskStats.compute(mask);
      _log.d('mask built', {
        'ms': maskSw.elapsedMilliseconds,
        ...maskStatsValue.toLogMap(),
      });
      if (maskStatsValue.isEffectivelyEmpty) {
        total.stop();
        _log.w('face mask is empty — faces may be out of bounds',
            {'ms': total.elapsedMilliseconds, ...maskStatsValue.toLogMap()});
        throw const PortraitSmoothException(
          "Couldn't apply the effect — the detected face fell "
          'outside the image bounds. Try reframing the photo.',
        );
      }

      // 5. Blur the source with a radius proportional to the
      //    average face width so small + large faces look
      //    equivalently softened. Use scaledFaces so the radius
      //    is in decoded-image pixels, not detection pixels.
      final avgFaceWidth = scaledFaces
              .map((f) => f.boundingBox.width)
              .reduce((a, b) => a + b) /
          scaledFaces.length;
      final rawRadius = (avgFaceWidth * blurRadiusFraction).round();
      final radius = rawRadius.clamp(minBlurRadius, maxBlurRadius);
      _log.d('blur radius', {
        'raw': rawRadius,
        'clamped': radius,
        'avgFaceWidth': avgFaceWidth.round(),
      });
      final blurSw = Stopwatch()..start();
      // Phase XII.A.2: bilateral-style edge-preserving blur instead
      // of plain box blur. Skin pores / smooth regions blur; eye
      // lashes, lip lines, brows, and stubble stay sharp because the
      // per-pixel detail differential gates the blend.
      final rawBlurred = EdgePreservingBlur.blurRgba(
        source: decoded.bytes,
        width: decoded.width,
        height: decoded.height,
        radius: radius,
        edgeThreshold: edgeThreshold,
      );
      // Phase XII.A.4: mix a fraction of the original micro-texture
      // back in so the result reads "smoothed but alive" instead of
      // plastic-doll.
      final blurred = EdgePreservingBlur.restoreDetail(
        smoothed: rawBlurred,
        source: decoded.bytes,
        restoration: detailRestoration,
      );
      blurSw.stop();
      _log.d('blur', {
        'ms': blurSw.elapsedMilliseconds,
        'detailRestoration': detailRestoration,
      });

      // 6. Composite blurred-over-original via the face mask.
      final compSw = Stopwatch()..start();
      final result = compositeOverlayRgba(
        base: decoded.bytes,
        overlay: blurred,
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
        'blurMs': blurSw.elapsedMilliseconds,
        'compositeMs': compSw.elapsedMilliseconds,
        'outputW': image.width,
        'outputH': image.height,
        'faces': faces.length,
      });
      return image;
    } on PortraitSmoothException {
      rethrow;
    } on BgRemovalIoException catch (e) {
      total.stop();
      _log.w('run IO failure — rewrapping', {
        'message': e.message,
        'ms': total.elapsedMilliseconds,
      });
      throw PortraitSmoothException(e.message, cause: e);
    } catch (e, st) {
      total.stop();
      _log.e('run failed',
          error: e, stackTrace: st, data: {'ms': total.elapsedMilliseconds});
      throw PortraitSmoothException(e.toString(), cause: e);
    }
  }

  /// Mark this service as closed. Does NOT close the underlying
  /// [detector] — the caller owns its lifecycle.
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _log.i('close');
  }

  /// Run Face Mesh, rasterise the face-oval polygon, then subtract
  /// the eye, brow and inner-lip polygons so brows / lashes / lip
  /// detail stay sharp through the smoothing pass. Returns null on
  /// any mesh failure; the caller falls back to the ellipse builder.
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
      final mask = PolygonMaskBuilder.build(
        polygon: [
          for (final i in FaceMeshIndices.faceOval) result.landmarks[i],
        ],
        width: decoded.width,
        height: decoded.height,
        featherRadius: 6,
      );
      // Subtract eye rings, brows, and inner mouth so those features
      // escape the blur. Mesh polygons are tight so a small feather
      // keeps the transition natural.
      _subtractPolygon(mask, result, decoded, FaceMeshIndices.leftEye);
      _subtractPolygon(mask, result, decoded, FaceMeshIndices.rightEye);
      _subtractPolygon(mask, result, decoded, FaceMeshIndices.leftEyebrow);
      _subtractPolygon(mask, result, decoded, FaceMeshIndices.rightEyebrow);
      _subtractPolygon(mask, result, decoded, FaceMeshIndices.innerLips);
      return mask;
    } catch (e, st) {
      _log.w('face mesh failed — falling back to ellipse mask', {
        'error': e.toString(),
        'stack': st.toString().split('\n').first,
      });
      return null;
    }
  }

  /// Multiply each mask entry inside [polygonIndices] by `(1 - stamp)`
  /// so the region the stamp covers becomes transparent in the mask.
  static void _subtractPolygon(
    Float32List mask,
    FaceMeshResult result,
    DecodedRgba decoded,
    List<int> polygonIndices,
  ) {
    final stamp = PolygonMaskBuilder.build(
      polygon: [for (final i in polygonIndices) result.landmarks[i]],
      width: decoded.width,
      height: decoded.height,
      featherRadius: 3,
    );
    for (int i = 0; i < mask.length; i++) {
      mask[i] *= 1.0 - stamp[i];
    }
  }
}

/// Typed exception surface for portrait smoothing failures. Callers
/// can distinguish by message prefix ("No face detected...") so the
/// UI can show a coaching message instead of a red error toast.
///
/// [cause] carries the underlying exception when this was rewrapped
/// (face detection failed, IO decode failed, etc.) so session logs
/// retain the original stack trace.
class PortraitSmoothException implements Exception {
  const PortraitSmoothException(this.message, {this.cause});
  final String message;
  final Object? cause;

  @override
  String toString() {
    if (cause == null) return 'PortraitSmoothException: $message';
    return 'PortraitSmoothException: $message (caused by $cause)';
  }
}
