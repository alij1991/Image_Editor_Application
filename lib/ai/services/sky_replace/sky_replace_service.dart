import 'dart:ui' as ui;

import '../../../core/logging/app_logger.dart';
import '../../inference/mask_stats.dart';
import '../../inference/rgba_compositor.dart';
import '../../inference/sky_mask_builder.dart';
import '../../inference/sky_palette.dart';
import '../bg_removal/image_io.dart';
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
  }) {
    // Log tuning params at construction so post-hoc triage can
    // correlate user-reported artifacts to the exact values the
    // service ran with. Matches the 9d/9e/9f service pattern.
    _log.i('created', {
      'threshold': threshold,
      'featherWidth': featherWidth,
      'maxCoverageRatio': maxCoverageRatio,
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
      // 1. Decode source.
      final decoded = await BgRemovalImageIo.decodeFileToRgba(sourcePath);
      _log.d('source decoded', {
        'path': sourcePath,
        'w': decoded.width,
        'h': decoded.height,
      });

      // 2. Build the sky mask.
      final maskSw = Stopwatch()..start();
      final mask = SkyMaskBuilder.build(
        source: decoded.bytes,
        width: decoded.width,
        height: decoded.height,
        threshold: threshold,
        featherWidth: featherWidth,
      );
      maskSw.stop();
      final stats = MaskStats.compute(mask);
      _log.d('mask built', {
        'ms': maskSw.elapsedMilliseconds,
        ...stats.toLogMap(),
      });
      if (stats.isEffectivelyEmpty) {
        total.stop();
        _log.w('sky mask is empty — no sky found in image',
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
