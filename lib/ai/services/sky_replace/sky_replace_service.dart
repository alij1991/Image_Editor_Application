import 'dart:ui' as ui;

import '../../../core/logging/app_logger.dart';
import '../../inference/mask_stats.dart';
import '../../inference/rgba_compositor.dart';
import '../../inference/sky_mask_builder.dart';
import '../../inference/sky_palette.dart';
import '../bg_removal/image_io.dart';
import '../semantic_segmentation/semantic_segmentation_service.dart';
import 'sky_preset.dart';

final _log = AppLogger('SkyReplaceService');

/// Phase 9g sky replacement pipeline.
///
/// Runs a pure-Dart heuristic sky segmentation on the source
/// image, generates a procedural replacement sky matching the
/// user-selected [SkyPreset], and composites the new sky into the
/// original through the segmentation mask. Returns a new
/// `ui.Image` the caller stores inside an [AdjustmentLayer] with
/// `kind == skyReplace`.
///
/// Trade-offs vs. a DeepLabV3-backed segmenter:
///
/// - The heuristic catches typical blue / bright / top-of-frame
///   sky pixels but misses night skies, heavily cloud-covered
///   low-contrast skies, and anything where sky wraps around
///   low obstacles. Users who hit a miss get a coaching message
///   instead of a silent no-op (see [MaskStats] empty-check).
/// - The replacement is a procedurally-generated gradient, not a
///   photographic HDR sky. Future phases can swap in a real sky
///   library behind the same [SkyPreset] interface without
///   touching the service.
///
/// Throws [SkyReplaceException] with a user-readable message for
/// every failure mode — the editor page shows it verbatim.
class SkyReplaceService {
  SkyReplaceService({
    this.threshold = 0.45,
    this.featherWidth = 0.12,
    this.maxCoverageRatio = 0.60,
    this.segmentation,
    this.skySegmentation,
  }) {
    // Log tuning params at construction so post-hoc triage can
    // correlate user-reported artifacts to the exact values the
    // service ran with. Matches the 9d/9e/9f service pattern.
    _log.i('created', {
      'threshold': threshold,
      'featherWidth': featherWidth,
      'maxCoverageRatio': maxCoverageRatio,
      'segmentation': segmentation != null,
      'skySegmentation': skySegmentation != null,
    });
  }

  /// Score cutoff passed to [SkyMaskBuilder.build]. Defaults to
  /// `0.45` — the empirical sweet spot for accepting clear-blue
  /// and soft-overcast skies without leaking into blue fabric
  /// or water in typical photos.
  final double threshold;

  /// Feather width passed to [SkyMaskBuilder.build]. Bigger = a
  /// softer seam between real scene and replacement sky. Default
  /// `0.12` hides the transition on most subjects without visibly
  /// smearing the skyline.
  final double featherWidth;

  /// VIII.10 — over-coverage rejection threshold. When the heuristic
  /// builds a mask covering more than this fraction of the frame, the
  /// service throws instead of producing an output. Real landscape
  /// skies almost never exceed ~50% coverage; >60% almost certainly
  /// means the detector latched onto a blue wall, water, or a tinted
  /// fabric. Surfaces the failure to the user instead of silently
  /// painting the whole image.
  final double maxCoverageRatio;

  /// Optional PASCAL-VOC semantic segmentation. When set, the service
  /// runs it once, builds a "non-sky object" soft mask (people, cars,
  /// animals, furniture, …) and multiplies `1 - objectMask` into the
  /// colour/top-bias sky mask. This cleans up the main failure mode
  /// of the pure heuristic: portraits-with-sky where the subject's
  /// skin/clothes happened to match the warm or bright-bluish score.
  final SemanticSegmentationService? segmentation;

  /// Optional ADE20K semantic segmentation. When set, the service
  /// runs it once and UNIONs its sky-class mask (ADE20K class 3)
  /// with the colour/top-bias heuristic mask. This adds positive-
  /// signal sky detection for cases the heuristic misses — heavy
  /// cloud cover, sunsets with low blue content, night skies — and
  /// is the primary reason Phase XIII.6 exists.
  final SemanticSegmentationService? skySegmentation;

  bool _closed = false;

  /// Run the full pipeline on the image at [sourcePath] with
  /// [preset] as the replacement sky, and return a new `ui.Image`.
  Future<ui.Image> replaceSkyFromPath({
    required String sourcePath,
    required SkyPreset preset,
  }) async {
    if (_closed) {
      _log.w('run rejected — service closed', {'path': sourcePath});
      throw const SkyReplaceException('SkyReplaceService is closed');
    }
    final total = Stopwatch()..start();
    _log.i('run start', {'path': sourcePath, 'preset': preset.name});

    try {
      // 1. Decode source at preview-quality so the output ui.Image
      //    downsamples cleanly onto the preview canvas instead of
      //    upscaling the 1024-wide heuristic result.
      final decoded = await BgRemovalImageIo.decodeFileToRgba(
        sourcePath,
        maxDimension: BgRemovalImageIo.previewQualityDecodeDimension,
      );
      _log.d('source decoded', {
        'path': sourcePath,
        'w': decoded.width,
        'h': decoded.height,
      });

      // 2. Build the sky mask from colour + top-bias.
      final maskSw = Stopwatch()..start();
      final mask = SkyMaskBuilder.build(
        source: decoded.bytes,
        width: decoded.width,
        height: decoded.height,
        threshold: threshold,
        featherWidth: featherWidth,
      );

      // 2a. If ADE20K segmentation is wired in, UNION its positive
      //     sky mask with the heuristic. The ADE20K model often
      //     classifies bright water reflections (lake, sea at
      //     golden-hour) as "sky" because they share the colour
      //     distribution. Gate the upgrade by the same top-bias
      //     curve the heuristic uses: pixels in the upper portion
      //     keep full weight, pixels in the lower 40% are rejected
      //     regardless of the model's classification. This cleans
      //     up the "replacement bleeds into the water" artefact.
      if (skySegmentation != null) {
        try {
          final skySw = Stopwatch()..start();
          final result = await skySegmentation!.runOnRgba(
            sourceRgba: decoded.bytes,
            sourceWidth: decoded.width,
            sourceHeight: decoded.height,
          );
          final skyMask = result.maskForClasses({
            SemanticSegmentationService.ade20kSkyClass,
          });
          final skyMaskFull = SegmentationResult.bilinearResize(
            src: skyMask,
            srcWidth: result.width,
            srcHeight: result.height,
            dstWidth: decoded.width,
            dstHeight: decoded.height,
          );
          int upgraded = 0;
          int rejectedBelowHorizon = 0;
          final topEnd = decoded.height * 0.6;
          for (int y = 0; y < decoded.height; y++) {
            final double topBias;
            if (y <= 0) {
              topBias = 1.0;
            } else if (y >= topEnd) {
              topBias = 0.0;
            } else {
              final t = 1 - (y / topEnd);
              topBias = t * t * (3 - 2 * t);
            }
            final rowOffset = y * decoded.width;
            for (int x = 0; x < decoded.width; x++) {
              final i = rowOffset + x;
              final s = skyMaskFull[i];
              if (s <= 0) continue;
              final gated = s * topBias;
              if (gated > mask[i]) {
                if (mask[i] < 0.5 && gated >= 0.5) upgraded++;
                mask[i] = gated;
              } else if (s >= 0.5 && topBias == 0.0) {
                rejectedBelowHorizon++;
              }
            }
          }
          skySw.stop();
          _log.d('ADE20K sky union applied', {
            'ms': skySw.elapsedMilliseconds,
            'upgradedPixels': upgraded,
            'rejectedBelowHorizon': rejectedBelowHorizon,
          });
        } catch (e, st) {
          _log.w('ADE20K sky segmentation failed — falling through', {
            'error': e.toString(),
            'stack': st.toString().split('\n').first,
          });
        }
      }

      // 2b. If PASCAL-VOC segmentation is wired in, multiply out the
      //     pixels any non-background class claims. This strips the
      //     false-positive sky on portraits / street scenes without
      //     hurting clear-sky landscape shots (where the segmenter
      //     returns mostly background anyway).
      if (segmentation != null) {
        try {
          final segSw = Stopwatch()..start();
          final result = await segmentation!.runOnRgba(
            sourceRgba: decoded.bytes,
            sourceWidth: decoded.width,
            sourceHeight: decoded.height,
          );
          final objectMask257 = result.objectMask();
          final objectMask = SegmentationResult.bilinearResize(
            src: objectMask257,
            srcWidth: result.width,
            srcHeight: result.height,
            dstWidth: decoded.width,
            dstHeight: decoded.height,
          );
          int rejected = 0;
          for (int i = 0; i < mask.length; i++) {
            final o = objectMask[i];
            if (o > 0) {
              final before = mask[i];
              mask[i] = before * (1.0 - o);
              if (before > 0.01) rejected++;
            }
          }
          segSw.stop();
          _log.d('segmentation filter applied', {
            'ms': segSw.elapsedMilliseconds,
            'rejectedPixels': rejected,
          });
        } catch (e, st) {
          // Never fail the op because of segmentation; it's an
          // enhancement, not a requirement. Fall through to the
          // pure-heuristic path.
          _log.w('segmentation filter failed — falling through', {
            'error': e.toString(),
            'stack': st.toString().split('\n').first,
          });
        }
      }
      maskSw.stop();
      final stats = MaskStats.compute(mask);
      _log.d('mask built', {
        'ms': maskSw.elapsedMilliseconds,
        ...stats.toLogMap(),
      });
      // Minimum-coverage guard: even when max > 0.01 (i.e. not
      // "effectively empty"), a mask covering < 0.5 % of the frame
      // at low alpha produces no visible sky replacement. The case
      // triggering this is typically an image with no sky at all
      // where the top-bias term awards a tiny score to a few bright
      // pixels at the very top edge.
      const minSkyCoverage = 0.005; // 0.5 % of frame
      if (stats.isEffectivelyEmpty || stats.coverageRatio < minSkyCoverage) {
        total.stop();
        _log.w('sky mask is empty or below minimum coverage',
            {'ms': total.elapsedMilliseconds, ...stats.toLogMap()});
        throw const SkyReplaceException(
          "Couldn't find any sky in the photo. Try a landscape "
          'shot with a clear view of the sky at the top of frame.',
        );
      }
      if (stats.isEffectivelyFull) {
        total.stop();
        _log.w('sky mask covers the whole image',
            {'ms': total.elapsedMilliseconds, ...stats.toLogMap()});
        throw const SkyReplaceException(
          'The whole image looks like sky — sky replacement has '
          'nothing to preserve. Pick a different photo.',
        );
      }
      // VIII.10 — over-coverage rejection. Even if not "effectively
      // full" (every pixel ≥ 0.99), a mask covering more than 60% of
      // the frame is almost never a real sky. Throw with a hint
      // instead of producing a misleading output.
      if (stats.coverageRatio > maxCoverageRatio) {
        total.stop();
        _log.w('sky mask over-coverage — likely not a sky photo', {
          'coverage': stats.coverageRatio.toStringAsFixed(3),
          'limit': maxCoverageRatio,
          'ms': total.elapsedMilliseconds,
          ...stats.toLogMap(),
        });
        throw const SkyReplaceException(
          "This doesn't look like a sky photo — the detector matched "
          'too much of the frame. Try a landscape with a clear sky '
          'and a recognisable horizon.',
        );
      }

      // 3. Generate the replacement sky at source resolution.
      final genSw = Stopwatch()..start();
      final replacement = SkyPalette.generate(
        preset: preset,
        width: decoded.width,
        height: decoded.height,
      );
      genSw.stop();
      _log.d('sky generated', {
        'ms': genSw.elapsedMilliseconds,
        'preset': preset.name,
      });

      // 4. Composite replacement-over-source via the sky mask.
      final compSw = Stopwatch()..start();
      final result = compositeOverlayRgba(
        base: decoded.bytes,
        overlay: replacement,
        mask: mask,
        width: decoded.width,
        height: decoded.height,
      );
      compSw.stop();
      _log.d('composite', {'ms': compSw.elapsedMilliseconds});

      // 5. Re-upload as a ui.Image.
      final image = await BgRemovalImageIo.encodeRgbaToUiImage(
        rgba: result,
        width: decoded.width,
        height: decoded.height,
      );
      total.stop();
      _log.i('run complete', {
        'totalMs': total.elapsedMilliseconds,
        'maskMs': maskSw.elapsedMilliseconds,
        'genMs': genSw.elapsedMilliseconds,
        'compositeMs': compSw.elapsedMilliseconds,
        'outputW': image.width,
        'outputH': image.height,
        'preset': preset.name,
      });
      return image;
    } on SkyReplaceException {
      rethrow;
    } on BgRemovalIoException catch (e) {
      total.stop();
      _log.w('run IO failure — rewrapping', {
        'message': e.message,
        'ms': total.elapsedMilliseconds,
      });
      throw SkyReplaceException(e.message, cause: e);
    } catch (e, st) {
      total.stop();
      _log.e('run failed',
          error: e,
          stackTrace: st,
          data: {'ms': total.elapsedMilliseconds});
      throw SkyReplaceException(e.toString(), cause: e);
    }
  }

  /// Mark this service as closed. Safe to call more than once.
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _log.i('close');
  }
}

/// Typed exception surface for sky replacement failures. Messages
/// are user-facing so the editor page can show them verbatim.
///
/// [cause] carries the underlying exception when this was rewrapped
/// so session logs retain the full failure chain — matches the
/// post-9c-audit pattern used by every other AI service.
class SkyReplaceException implements Exception {
  const SkyReplaceException(this.message, {this.cause});
  final String message;
  final Object? cause;

  @override
  String toString() {
    if (cause == null) return 'SkyReplaceException: $message';
    return 'SkyReplaceException: $message (caused by $cause)';
  }
}
