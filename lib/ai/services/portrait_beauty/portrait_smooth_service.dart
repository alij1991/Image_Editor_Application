import 'dart:math' as math;
import 'dart:ui' as ui;

import '../../../core/logging/app_logger.dart';
import '../../inference/box_blur.dart';
import '../../inference/face_mask_builder.dart';
import '../../inference/mask_stats.dart';
import '../../inference/rgba_compositor.dart';
import '../bg_removal/image_io.dart';
import '../face_detect/face_detection_service.dart';

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
    this.featherFraction = 0.35,
    this.blurRadiusFraction = 0.03,
    this.minBlurRadius = 3,
    this.maxBlurRadius = 18,
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
    });
  }

  /// The face detector to run at apply time. Ownership stays with
  /// the caller; [close] does NOT close the detector so the caller
  /// can reuse it across invocations.
  final FaceDetectionService detector;

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

      // 4. Build the face mask from the detected bounding boxes +
      //    landmarks. Same-res as the source so no upsample is
      //    needed later.
      final maskSw = Stopwatch()..start();
      final mask = FaceMaskBuilder.build(
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
      final blurred = BoxBlur.blurRgba(
        source: decoded.bytes,
        width: decoded.width,
        height: decoded.height,
        radius: radius,
      );
      blurSw.stop();
      _log.d('blur', {'ms': blurSw.elapsedMilliseconds});

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
