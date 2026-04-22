import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import '../../../core/logging/app_logger.dart';
import '../../inference/landmark_mask_builder.dart';
import '../../inference/mask_stats.dart';
import '../../inference/polygon_mask_builder.dart';
import '../../inference/rgb_ops.dart';
import '../../inference/rgba_compositor.dart';
import '../bg_removal/image_io.dart';
import '../face_detect/face_detection_service.dart';
import '../face_mesh/face_mesh_service.dart';

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
    this.faceMesh,
    this.yellowRemoval = 0.65,
    this.luminanceBoost = 6.0,
    this.mouthRadiusFraction = 0.42,
    this.minRadius = 5,
    this.maxRadius = 70,
    this.feather = 0.6,
  }) {
    _log.i('created', {
      'yellowRemoval': yellowRemoval,
      'luminanceBoost': luminanceBoost,
      'mouthRadiusFraction': mouthRadiusFraction,
      'minRadius': minRadius,
      'maxRadius': maxRadius,
      'feather': feather,
      'faceMesh': faceMesh != null,
    });
  }

  /// The face detector, owned by the caller.
  final FaceDetectionService detector;

  /// Optional MediaPipe Face Mesh — when present, the service uses
  /// the 20-point inner-mouth polygon as the target mask instead of
  /// a disc around the mouth centre. That lands the whitening ONLY
  /// on enamel (when the mouth is open) or on a tiny lip-line strip
  /// (when closed, which the luminance/saturation gate then rejects
  /// as "no visible teeth"). Null callers fall back to the legacy
  /// disc-around-landmark mask.
  ///
  /// The caller owns the service — [close] does NOT close it.
  final FaceMeshService? faceMesh;

  /// Fraction of the current `b*` (yellow) to null out in CIE
  /// L*a*b* space. `0` = no change, `1` = fully neutral yellow.
  /// `0.65` leaves enamel looking warm-natural.
  final double yellowRemoval;

  /// Additive lift to `L*` in the 0..100 LAB scale. `6.0` is a
  /// noticeable brightening; `12+` starts to look bleached.
  final double luminanceBoost;

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
      //    resolution before building mouth spots. Uses preview-quality
      //    dimension (2 048 px) so the output layer is rendered at or
      //    above the preview resolution — no upscaling softness on top
      //    of the whitening.
      final decoded = await BgRemovalImageIo.decodeFileToRgba(
        sourcePath,
        maxDimension: BgRemovalImageIo.previewQualityDecodeDimension,
      );
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

      // 3. Build the mouth mask. Prefer the Face Mesh 20-point
      //    inner-lips polygon when available (precisely the visible
      //    teeth region); fall back to the legacy disc-around-landmark
      //    when the mesh model isn't loaded or the inference failed.
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
          _log.w('no mouth landmarks', {
            'ms': total.elapsedMilliseconds,
            'faces': scaledFaces.length,
          });
          throw const TeethWhitenException(
            "Couldn't find mouth landmarks. Try a sharper photo where "
            "the subject's mouth is clearly visible.",
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
        'source': faceMesh != null ? 'mesh-or-fallback' : 'legacy-disc',
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

      // 4a. Narrow the mouth-circle mask to tooth-like pixels only.
      // The ML Kit mouth landmarks sit ON the closed lip line, so the
      // bare landmark mask paints the whole lip region — applying the
      // desaturate+brighten kernel to lipstick-pink pixels simply
      // bleaches the lips. Gate by luminance (teeth are ≥ ~0.5) and
      // saturation (teeth are < ~0.25) so coloured / dark lip pixels
      // stay untouched. When the mouth is closed the gate zeroes the
      // mask almost everywhere and we fail gracefully below.
      _applyToothColorGate(mask, decoded.bytes);
      final gatedStats = MaskStats.compute(mask);
      _log.d('tooth-color gated', gatedStats.toLogMap());
      if (gatedStats.coverageRatio < 0.0002) {
        throw const TeethWhitenException(
          "Couldn't find any visible teeth — the mouth looks closed "
          'or the lips are masking the tooth area. Try a photo where '
          'the teeth are showing.',
        );
      }

      // 5. Whiten a full copy of the source in CIE L*a*b* space.
      // Phase XII.A.3: LAB-space lift preserves the blue-white cast
      // of healthy enamel; the old RGB desaturate+multiply pushed
      // teeth toward grey by killing every channel's hue.
      final opSw = Stopwatch()..start();
      final whitened = RgbOps.whitenLab(
        source: decoded.bytes,
        width: decoded.width,
        height: decoded.height,
        yellowRemoval: yellowRemoval,
        luminanceBoost: luminanceBoost,
      );
      opSw.stop();
      _log.d('whiten', {
        'ms': opSw.elapsedMilliseconds,
        'yellowRemoval': yellowRemoval,
        'luminanceBoost': luminanceBoost,
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
        'faces': scaledFaces.length,
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

  /// Run Face Mesh on the decoded buffer and rasterise the inner-lips
  /// polygon. Returns null when the mesh model isn't available, the
  /// inference confidence is below threshold, or anything else trips
  /// up the crop pipeline — the caller then falls back to the legacy
  /// disc-around-landmark mask.
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
      if (result == null) {
        _log.d('face mesh returned null — falling back to legacy mask');
        return null;
      }
      final polygon = <ui.Offset>[
        for (final idx in FaceMeshIndices.innerLips) result.landmarks[idx],
      ];
      return PolygonMaskBuilder.build(
        polygon: polygon,
        width: decoded.width,
        height: decoded.height,
        featherRadius: 2,
      );
    } catch (e, st) {
      // Don't surface mesh errors to the user — we have a working
      // fallback. Log at warn level so post-hoc triage can spot a
      // systematically broken mesh path.
      _log.w('face mesh failed — falling back to legacy mask', {
        'error': e.toString(),
        'stack': st.toString().split('\n').first,
      });
      return null;
    }
  }

  /// Multiply every mask entry by a tooth-color smoothstep weight.
  ///
  /// Teeth are characterised by high luminance (~0.6+) and low
  /// saturation (~0.2 or less). Lips — with or without lipstick —
  /// sit in the opposite corner (moderate luminance, high
  /// saturation). Gating by both keeps the whitening off lips and
  /// skin while letting a narrow strip of visible enamel through
  /// at full strength.
  static void _applyToothColorGate(Float32List mask, Uint8List rgba) {
    for (var i = 0; i < mask.length; i++) {
      final m = mask[i];
      if (m <= 0) continue;
      final pix = i * 4;
      final r = rgba[pix].toDouble();
      final g = rgba[pix + 1].toDouble();
      final b = rgba[pix + 2].toDouble();
      final maxC = r > g ? (r > b ? r : b) : (g > b ? g : b);
      final minC = r < g ? (r < b ? r : b) : (g < b ? g : b);
      final lum = (0.2126 * r + 0.7152 * g + 0.0722 * b) / 255.0;
      final sat = maxC > 0 ? (maxC - minC) / maxC : 0.0;
      // Luminance smoothstep: below 0.45 = zero, above 0.65 = one.
      final lt = ((lum - 0.45) / 0.20).clamp(0.0, 1.0);
      final lumGate = lt * lt * (3 - 2 * lt);
      // Saturation smoothstep (inverted): above 0.35 = zero, below 0.15 = one.
      final st = ((0.35 - sat) / 0.20).clamp(0.0, 1.0);
      final satGate = st * st * (3 - 2 * st);
      mask[i] = m * lumGate * satGate;
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
