import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';

import '../../../../ai/services/bg_removal/bg_removal_strategy.dart';
import '../../../../ai/services/bg_removal/image_io.dart';
import '../../../../ai/services/compose_on_bg/compose_edge_refine.dart';
import '../../../../ai/services/denoise/ai_denoise_service.dart';
import '../../../../ai/services/face_detect/face_detection_service.dart';
import '../../../../ai/services/face_restore/face_restore_service.dart';
import '../../../../ai/services/inpaint/inpaint_service.dart';
import '../../../../ai/services/portrait_beauty/eye_brighten_service.dart';
import '../../../../ai/services/portrait_beauty/face_reshape_service.dart';
import '../../../../ai/services/portrait_beauty/portrait_smooth_service.dart';
import '../../../../ai/services/portrait_beauty/teeth_whiten_service.dart';
import '../../../../ai/services/compose_on_bg/compose_on_background_service.dart';
import '../../../../ai/services/selfie_segmentation/hair_clothes_recolour_service.dart';
import '../../../../ai/services/sharpen/ai_sharpen_service.dart';
import '../../../../ai/services/sky_replace/sky_preset.dart';
import '../../../../ai/services/sky_replace/sky_replace_service.dart';
import '../../../../ai/services/style_transfer/style_transfer_service.dart';
import '../../../../ai/services/super_res/super_res_service.dart';
import '../../../../core/async/generation_guard.dart';
import '../../../../core/logging/app_logger.dart';
import '../../../../engine/layers/content_layer.dart';
import '../../../../engine/layers/cutout_store.dart';
import '../../../../engine/pipeline/edit_pipeline.dart';
import '../../../../engine/pipeline/pipeline_extensions.dart';

final _log = AppLogger('AiCoord');

/// Signature of the "append an adjustment layer op + commit through
/// the history bloc" callback the session wires into the coordinator
/// so the coordinator's `applyXxx` methods can commit without
/// importing the history bloc / edit operation plumbing themselves.
typedef CommitAdjustmentLayer = void Function({
  required AdjustmentLayer layer,
  required String presetName,
});

/// Phase XVI.11: two-layer atomic commit used by the compose-on-bg
/// flow so the background layer and subject layer land as one
/// history entry (a single undo rolls both back together).
typedef CommitAdjustmentLayerPair = void Function({
  required AdjustmentLayer first,
  required AdjustmentLayer second,
  required String presetName,
});

/// Signature of the session-level face-detection cache. Routes
/// through [FaceDetectionCache] so three sequential beauty ops on the
/// same source pay ML Kit face detection once.
typedef DetectFaces = Future<List<DetectedFace>> Function(
    FaceDetectionService detector);

/// Owns the volatile cutout bitmap cache, the shared dispose-guarded
/// inference wrapper, and the 9 `applyXxx` methods the UI drives.
///
/// Extracted from `editor_session.dart` across Phase VII.2 + VII.4 of
/// the session decomposition. Three concerns live here:
///
///   1. **Cutout cache (the `_cutoutImages` map, VII.2)** — every
///      [AdjustmentLayer] stashes its decoded `ui.Image` here so
///      `rebuildPreview` can fill it in when iterating the pipeline.
///      Writes bump a [GenerationGuard] stamp so an in-flight PNG
///      hydrate for the same layer self-drops instead of overwriting
///      a fresh AI result. PNG persistence to [CutoutStore] is
///      fire-and-forget from the sync [cacheCutoutImage] call.
///
///   2. **Dispose-guarded inference wrapper ([runInference], VII.2)**
///      — pre-await + post-await disposal checks + typed-exception
///      rethrow-or-wrap. Every apply method's shared boilerplate.
///
///   3. **The 9 `applyXxx` methods (VII.4)** — background removal,
///      portrait smooth, eye brighten, teeth whiten, face reshape,
///      sky replace, enhance (super-res), style transfer, inpainting.
///      Each runs the service through [runInference], caches the
///      cutout, and commits an [AdjustmentLayer] to the pipeline via
///      the session-provided [commitAdjustmentLayer] callback. The 4
///      beauty ops that need face landmarks route through the
///      session's [detectFaces] callback so the session-scoped cache
///      stays authoritative.
///
/// Session-side dependencies are injected as callbacks
/// ([commitAdjustmentLayer], [detectFaces]) so this class doesn't
/// reach into the session's HistoryBloc or face-detection cache.
///
/// Lifecycle: [dispose] flips an internal `_disposed` flag so pending
/// [persistCutout] / [hydrate] / in-flight inference awaits bail,
/// disposes every cached bitmap, and clears the map. Safe to call
/// twice.
class AiCoordinator {
  AiCoordinator({
    required this.sourcePath,
    required this.cutoutStore,
    required this.onHydrateLanded,
    required this.commitAdjustmentLayer,
    required this.commitAdjustmentLayerPair,
    required this.detectFaces,
  });

  final String sourcePath;
  final CutoutStore cutoutStore;

  /// Called once after [hydrate] decodes ≥ 1 cutout from disk. The
  /// session wires this to `rebuildPreview` so the canvas picks up
  /// the restored layers.
  final VoidCallback onHydrateLanded;

  /// Session-provided bridge to `historyBloc.add(ApplyPipelineEvent(
  /// pipeline: committedPipeline.append(op), presetName: presetName))`
  /// for an [AdjustmentLayer] op. Called by every `applyXxx` method
  /// after the cutout lands so the coordinator never imports the
  /// history bloc / edit-op plumbing.
  final CommitAdjustmentLayer commitAdjustmentLayer;

  /// Phase XVI.11 — atomic two-layer commit bridge for compose-on-bg.
  /// Appends the background + subject ops as a single
  /// `ApplyPipelineEvent` so one undo rolls the pair back.
  final CommitAdjustmentLayerPair commitAdjustmentLayerPair;

  /// Routes through the session's face-detection cache so the four
  /// beauty ops share one ML Kit invocation per source path per
  /// session.
  final DetectFaces detectFaces;

  /// Volatile cutout bitmaps for `AdjustmentLayer`s, keyed by layer id.
  ///
  /// Writes via [cacheCutoutImage] dispose the prior bitmap (if any)
  /// before inserting the new one to keep GPU memory bounded. Reads
  /// via [cutoutImageFor] are the authoritative source `rebuildPreview`
  /// consults — the pipeline op only carries metadata, the bitmap
  /// lives here.
  final Map<String, ui.Image> _cutoutImages = {};

  /// Phase XVI.15 — raw (straight-alpha, pre-feather, pre-decontam,
  /// pre-premultiply) subject pixels per compose-subject layer id.
  /// Stashed at compose time so [rebakeComposeSubjectEdges] can
  /// re-apply the refine without re-running the bg-removal matte.
  /// Lost on session reload (the bg layer is persisted via
  /// [cutoutStore] but the raw pre-refine bytes are not — on reload
  /// the refine is replayed against the persisted already-baked image
  /// so the result is approximate, not bit-exact). Evicted when
  /// [dispose] is called.
  final Map<String, _ComposeSubjectRaw> _composeSubjectRaw = {};

  /// Per-layer async-commit guard for PNG decodes during [hydrate].
  /// [cacheCutoutImage] bumps the counter so a stale disk decode
  /// that finishes after a fresh AI segmentation lands drops its
  /// bitmap instead of overwriting the newer one.
  final GenerationGuard<String> _cutoutGen = GenerationGuard<String>();

  bool _disposed = false;

  /// Number of cached bitmaps currently in the map. Used by the
  /// session's rebuildPreview log + tests that pin cache sizing.
  int get cutoutCount => _cutoutImages.length;

  /// Observable persist counters so tests can pin "cache triggered
  /// exactly N disk writes" without reaching into internal state.
  @visibleForTesting
  int debugPersistSuccessCount = 0;
  @visibleForTesting
  int debugPersistFailureCount = 0;

  /// Observable hydrate counters for test assertions on the restore
  /// path.
  @visibleForTesting
  int debugHydrateSuccessCount = 0;
  @visibleForTesting
  int debugHydrateMissCount = 0;

  /// Lookup — returns null if no bitmap has been cached for [layerId].
  ui.Image? cutoutImageFor(String layerId) => _cutoutImages[layerId];

  /// Store a decoded cutout image for an [AdjustmentLayer] id. Called
  /// when an AI feature produces a new mask.
  ///
  ///   * Any existing image for the same id is disposed first — avoids
  ///     leaking GPU memory when a re-segment replaces the cutout.
  ///   * Bumps [_cutoutGen] so any in-flight [hydrate] PNG decode
  ///     for the same layer self-drops (the AI-produced cutout is the
  ///     authoritative one; don't let a slower disk read overwrite it).
  ///   * Kicks off a fire-and-forget PNG encode + [CutoutStore.put] so
  ///     the next session can restore the same layer without re-running
  ///     the AI op. IO failures log but never surface to the user —
  ///     they still see the cutout *this* session.
  void cacheCutoutImage(String layerId, ui.Image image) {
    if (_disposed) {
      image.dispose();
      return;
    }
    // Phase XVI.17 — reuse the one generation bump for BOTH hydrate
    // race guard AND persist-skip-if-superseded. Without forwarding
    // the stamp into `_persistCutout`, an edge-refine slider drag
    // (~30 cacheCutoutImage calls/sec) would write every intermediate
    // PNG to disk; with it, only the last one survives the post-
    // await `isLatest` check.
    final stamp = _cutoutGen.begin(layerId);
    final prev = _cutoutImages.remove(layerId);
    prev?.dispose();
    _cutoutImages[layerId] = image;
    _log.d('cached cutout', {
      'id': layerId,
      'width': image.width,
      'height': image.height,
    });
    unawaited(_persistCutout(layerId, image, stamp));
  }

  /// Async half of [cacheCutoutImage]. Encodes [image] to PNG on the
  /// UI isolate (Flutter's `toByteData` marshals through Skia's
  /// background thread; non-blocking for the UI isolate) and writes
  /// the bytes through [cutoutStore]. On any failure the session
  /// proceeds as if persistence never happened.
  Future<void> _persistCutout(
    String layerId,
    ui.Image image,
    int stamp,
  ) async {
    if (_disposed) return;
    try {
      final byteData = await image.toByteData(format: ui.ImageByteFormat.png);
      if (byteData == null) {
        _log.w('cutout encode returned null', {'id': layerId});
        debugPersistFailureCount++;
        return;
      }
      if (_disposed) return;
      // Drop the write if a newer cacheCutoutImage has landed since
      // our encode started — its persist is queued behind ours and
      // carries fresher bytes. Saves the file system from a write
      // storm during edge-refine slider drags (Phase XVI.17).
      if (!_cutoutGen.isLatest(layerId, stamp)) return;
      await cutoutStore.put(
        sourcePath: sourcePath,
        layerId: layerId,
        pngBytes: byteData.buffer.asUint8List(),
      );
      debugPersistSuccessCount++;
    } catch (e, st) {
      debugPersistFailureCount++;
      _log.w('cutout persist failed', {
        'id': layerId,
        'error': e.toString(),
      });
      _log.e('cutout persist trace', error: e, stackTrace: st);
    }
  }

  /// On session start, load cached PNGs from [cutoutStore] for every
  /// [AdjustmentLayer] in the restored [pipeline]. Without this, AI
  /// layers appear present in the pipeline but render as empty — the
  /// user sees their background-removed photo with the background
  /// back, for example.
  ///
  /// Runs once, fire-and-forget from the session's `start`. Missing
  /// cutouts are silently tolerated: the cutout may have been evicted
  /// by the disk-budget pass, or this may be a first-load before any
  /// AI op has run. Either way, the layer stays visible but empty
  /// until the user re-runs the AI op.
  ///
  /// Calls [onHydrateLanded] once after the loop if at least one PNG
  /// decoded — the session uses this to trigger a single preview
  /// rebuild at the end of the hydrate instead of N partial rebuilds.
  Future<void> hydrate(EditPipeline pipeline) async {
    if (_disposed) return;
    final adjustments = pipeline.contentLayers.whereType<AdjustmentLayer>();
    if (adjustments.isEmpty) return;
    int hydrated = 0;
    for (final layer in adjustments) {
      if (_disposed) return;
      if (_cutoutImages.containsKey(layer.id)) continue;
      // Race guard: stamp the slot before the async decode. If an AI
      // op ([cacheCutoutImage]) claims the same layer during our
      // await, its `begin` bumps the counter and our `isLatest` check
      // on commit returns false — we drop the decoded image instead
      // of overwriting the AI result.
      final stamp = _cutoutGen.begin(layer.id);
      try {
        final bytes = await cutoutStore.get(
          sourcePath: sourcePath,
          layerId: layer.id,
        );
        if (bytes == null) {
          debugHydrateMissCount++;
          continue;
        }
        if (_disposed) return;
        final codec = await ui.instantiateImageCodec(bytes);
        final frame = await codec.getNextFrame();
        codec.dispose();
        if (_disposed) {
          frame.image.dispose();
          return;
        }
        if (!_cutoutGen.isLatest(layer.id, stamp)) {
          // A fresh AI segmentation landed while we were decoding —
          // our PNG bytes are stale relative to it.
          frame.image.dispose();
          continue;
        }
        _cutoutImages[layer.id] = frame.image;
        hydrated++;
        debugHydrateSuccessCount++;
        _log.d('hydrated cutout', {
          'id': layer.id,
          'w': frame.image.width,
          'h': frame.image.height,
        });
      } catch (e) {
        debugHydrateMissCount++;
        _log.w('hydrate cutout failed', {
          'id': layer.id,
          'error': e.toString(),
        });
      }
    }
    if (hydrated > 0 && !_disposed) {
      _log.i('cutouts hydrated', {
        'count': hydrated,
        'total': adjustments.length,
      });
      onHydrateLanded();
    }
  }

  /// Run an AI inference with pre/post-await disposal guards and
  /// typed-exception wrapping. Collapses the boilerplate every
  /// `applyXxx` method in the session used to hand-roll.
  ///
  /// Flow:
  ///   1. If disposed → log rejection + throw [makeException].
  ///   2. Run [infer]; if it throws and [rethrowTyped] returns true,
  ///      log `'service failed'` + rethrow as-is so the caller sees the
  ///      original typed exception. Otherwise log `'service crashed'`
  ///      with full stack trace + wrap via [makeException].
  ///   3. Post-await disposal check → dispose the returned image +
  ///      throw [makeException] with the `'Session closed during
  ///      inference'` message. Matches the pre-VII.2 lifecycle exactly.
  ///
  /// On success returns the image. The caller is responsible for
  /// either [cacheCutoutImage]-ing it or disposing it.
  Future<ui.Image> runInference<E extends Object>({
    required String logTag,
    required String layerId,
    required Future<ui.Image> Function() infer,
    required bool Function(Object error) rethrowTyped,
    required E Function(String message) makeException,
    Map<String, Object?> extraLogData = const {},
  }) async {
    if (_disposed) {
      _log.w('$logTag rejected — session disposed', {
        'layerId': layerId,
        ...extraLogData,
      });
      throw makeException('Session is disposed');
    }
    final sw = Stopwatch()..start();
    _log.i('$logTag start', {
      'layerId': layerId,
      'sourcePath': sourcePath,
      ...extraLogData,
    });
    final ui.Image image;
    try {
      image = await infer();
    } catch (e, st) {
      sw.stop();
      if (rethrowTyped(e)) {
        _log.w('$logTag service failed', {
          'layerId': layerId,
          'ms': sw.elapsedMilliseconds,
          'message': e.toString(),
        });
        rethrow;
      }
      _log.e('$logTag service crashed',
          error: e,
          stackTrace: st,
          data: {
            'layerId': layerId,
            'ms': sw.elapsedMilliseconds,
          });
      throw makeException(e.toString());
    }
    if (_disposed) {
      sw.stop();
      _log.w('$logTag aborted — session disposed during inference', {
        'layerId': layerId,
        'ms': sw.elapsedMilliseconds,
      });
      image.dispose();
      throw makeException('Session closed during inference');
    }
    sw.stop();
    _log.d('$logTag inference complete', {
      'layerId': layerId,
      'ms': sw.elapsedMilliseconds,
      'w': image.width,
      'h': image.height,
    });
    return image;
  }

  // ---------------------------------------------------------------------------
  // Phase VII.4: the 9 public `applyXxx` entry points. Each runs the
  // service through [runInference], caches the cutout bitmap via
  // [cacheCutoutImage], and commits an [AdjustmentLayer] op through
  // [commitAdjustmentLayer]. The 4 beauty ops prefix a face-detection
  // step (routed through [detectFaces]) and wrap `FaceDetectionException`
  // as their own typed exception with a "Face detection failed: …"
  // message so the UI can coach the user.
  // ---------------------------------------------------------------------------

  /// Run background removal via [strategy] (MediaPipe / MODNet / RMBG),
  /// cache the resulting cutout, and commit a new
  /// [AdjustmentKind.backgroundRemoval] layer. Throws
  /// [BgRemovalException] on inference failure.
  Future<String> applyBackgroundRemoval({
    required BgRemovalStrategy strategy,
    required String newLayerId,
  }) async {
    final cutoutImage = await runInference(
      logTag: 'applyBackgroundRemoval',
      layerId: newLayerId,
      infer: () => strategy.removeBackgroundFromPath(sourcePath),
      rethrowTyped: (e) => e is BgRemovalException,
      makeException: (msg) => BgRemovalException(msg, kind: strategy.kind),
      extraLogData: {'strategy': strategy.kind.name},
    );
    cacheCutoutImage(newLayerId, cutoutImage);
    commitAdjustmentLayer(
      layer: AdjustmentLayer(
        id: newLayerId,
        adjustmentKind: AdjustmentKind.backgroundRemoval,
      ),
      presetName: 'Remove background',
    );
    return newLayerId;
  }

  /// Run face detection + portrait smoothing via [service]. Face
  /// detection is routed through [detectFaces] so three beauty ops
  /// on the same source pay ML Kit once.
  Future<String> applyPortraitSmooth({
    required PortraitSmoothService service,
    required String newLayerId,
  }) async {
    final faces = await _detectFacesOrThrow<PortraitSmoothException>(
      service.detector,
      (message, cause) =>
          PortraitSmoothException(message, cause: cause),
    );
    final cutoutImage = await runInference(
      logTag: 'applyPortraitSmooth',
      layerId: newLayerId,
      infer: () => service.smoothFromPath(sourcePath, preloadedFaces: faces),
      rethrowTyped: (e) => e is PortraitSmoothException,
      makeException: PortraitSmoothException.new,
    );
    cacheCutoutImage(newLayerId, cutoutImage);
    commitAdjustmentLayer(
      layer: AdjustmentLayer(
        id: newLayerId,
        adjustmentKind: AdjustmentKind.portraitSmooth,
      ),
      presetName: 'Smooth skin',
    );
    return newLayerId;
  }

  Future<String> applyEyeBrighten({
    required EyeBrightenService service,
    required String newLayerId,
  }) async {
    final faces = await _detectFacesOrThrow<EyeBrightenException>(
      service.detector,
      (message, cause) => EyeBrightenException(message, cause: cause),
    );
    final cutoutImage = await runInference(
      logTag: 'applyEyeBrighten',
      layerId: newLayerId,
      infer: () => service.brightenFromPath(sourcePath, preloadedFaces: faces),
      rethrowTyped: (e) => e is EyeBrightenException,
      makeException: EyeBrightenException.new,
    );
    cacheCutoutImage(newLayerId, cutoutImage);
    commitAdjustmentLayer(
      layer: AdjustmentLayer(
        id: newLayerId,
        adjustmentKind: AdjustmentKind.eyeBrighten,
      ),
      presetName: 'Brighten eyes',
    );
    return newLayerId;
  }

  Future<String> applyTeethWhiten({
    required TeethWhitenService service,
    required String newLayerId,
  }) async {
    final faces = await _detectFacesOrThrow<TeethWhitenException>(
      service.detector,
      (message, cause) => TeethWhitenException(message, cause: cause),
    );
    final cutoutImage = await runInference(
      logTag: 'applyTeethWhiten',
      layerId: newLayerId,
      infer: () => service.whitenFromPath(sourcePath, preloadedFaces: faces),
      rethrowTyped: (e) => e is TeethWhitenException,
      makeException: TeethWhitenException.new,
    );
    cacheCutoutImage(newLayerId, cutoutImage);
    commitAdjustmentLayer(
      layer: AdjustmentLayer(
        id: newLayerId,
        adjustmentKind: AdjustmentKind.teethWhiten,
      ),
      presetName: 'Whiten teeth',
    );
    return newLayerId;
  }

  /// Face reshape passes [reshapeParams] onto the layer so a future
  /// reload can re-run the warp without guessing which preset was used.
  Future<String> applyFaceReshape({
    required FaceReshapeService service,
    required String newLayerId,
    required Map<String, double> reshapeParams,
  }) async {
    final faces = await _detectFacesOrThrow<FaceReshapeException>(
      service.detector,
      (message, cause) => FaceReshapeException(message, cause: cause),
    );
    final cutoutImage = await runInference(
      logTag: 'applyFaceReshape',
      layerId: newLayerId,
      infer: () => service.reshapeFromPath(sourcePath, preloadedFaces: faces),
      rethrowTyped: (e) => e is FaceReshapeException,
      makeException: FaceReshapeException.new,
      extraLogData: {'reshapeParams': reshapeParams},
    );
    cacheCutoutImage(newLayerId, cutoutImage);
    commitAdjustmentLayer(
      layer: AdjustmentLayer(
        id: newLayerId,
        adjustmentKind: AdjustmentKind.faceReshape,
        reshapeParams: Map<String, double>.unmodifiable(reshapeParams),
      ),
      presetName: 'Sculpt face',
    );
    return newLayerId;
  }

  /// [preset] is serialized onto the layer as `skyPresetName` so a
  /// future reload / Rust export can reproduce the swap with the same
  /// palette.
  Future<String> applySkyReplace({
    required SkyReplaceService service,
    required String newLayerId,
    required SkyPreset preset,
  }) async {
    final cutoutImage = await runInference(
      logTag: 'applySkyReplace',
      layerId: newLayerId,
      infer: () =>
          service.replaceSkyFromPath(sourcePath: sourcePath, preset: preset),
      rethrowTyped: (e) => e is SkyReplaceException,
      makeException: SkyReplaceException.new,
      extraLogData: {'preset': preset.name},
    );
    cacheCutoutImage(newLayerId, cutoutImage);
    commitAdjustmentLayer(
      layer: AdjustmentLayer(
        id: newLayerId,
        adjustmentKind: AdjustmentKind.skyReplace,
        skyPresetName: preset.persistKey,
      ),
      presetName: 'Replace sky',
    );
    return newLayerId;
  }

  Future<String> applyEnhance({
    required SuperResService service,
    required String newLayerId,
  }) async {
    final cutoutImage = await runInference(
      logTag: 'applyEnhance',
      layerId: newLayerId,
      infer: () => service.enhanceFromPath(sourcePath),
      rethrowTyped: (e) => e is SuperResException,
      makeException: SuperResException.new,
    );
    cacheCutoutImage(newLayerId, cutoutImage);
    commitAdjustmentLayer(
      layer: AdjustmentLayer(
        id: newLayerId,
        adjustmentKind: AdjustmentKind.superResolution,
      ),
      presetName: 'Enhance (4×)',
    );
    return newLayerId;
  }

  Future<String> applyStyleTransfer({
    required StyleTransferService service,
    required Float32List styleVector,
    required String styleName,
    required String newLayerId,
  }) async {
    final cutoutImage = await runInference(
      logTag: 'applyStyleTransfer',
      layerId: newLayerId,
      infer: () =>
          service.transferFromPath(sourcePath, styleVector: styleVector),
      rethrowTyped: (e) => e is StyleTransferException,
      makeException: StyleTransferException.new,
      extraLogData: {'style': styleName},
    );
    cacheCutoutImage(newLayerId, cutoutImage);
    commitAdjustmentLayer(
      layer: AdjustmentLayer(
        id: newLayerId,
        adjustmentKind: AdjustmentKind.styleTransfer,
      ),
      presetName: 'Style: $styleName',
    );
    return newLayerId;
  }

  Future<String> applyInpainting({
    required InpaintService service,
    required Uint8List maskRgba,
    required int maskWidth,
    required int maskHeight,
    required String newLayerId,
  }) async {
    final cutoutImage = await runInference(
      logTag: 'applyInpainting',
      layerId: newLayerId,
      infer: () => service.inpaintFromPath(
        sourcePath,
        maskRgba: maskRgba,
        maskWidth: maskWidth,
        maskHeight: maskHeight,
      ),
      rethrowTyped: (e) => e is InpaintException,
      makeException: InpaintException.new,
      extraLogData: {'maskW': maskWidth, 'maskH': maskHeight},
    );
    cacheCutoutImage(newLayerId, cutoutImage);
    commitAdjustmentLayer(
      layer: AdjustmentLayer(
        id: newLayerId,
        adjustmentKind: AdjustmentKind.inpaint,
      ),
      presetName: 'Object removal',
    );
    return newLayerId;
  }

  /// Phase XVI.66a — AI denoise (DnCNN-color). Stateless ORT-only
  /// service so the apply method matches the same shape as
  /// [applyEnhance] / [applyInpainting]: run inference → cache →
  /// commit. Throws [AiDenoiseException] on inference failure.
  Future<String> applyAiDenoise({
    required AiDenoiseService service,
    required String newLayerId,
  }) async {
    final cutoutImage = await runInference(
      logTag: 'applyAiDenoise',
      layerId: newLayerId,
      infer: () => service.denoiseFromPath(sourcePath),
      rethrowTyped: (e) => e is AiDenoiseException,
      makeException: AiDenoiseException.new,
    );
    cacheCutoutImage(newLayerId, cutoutImage);
    commitAdjustmentLayer(
      layer: AdjustmentLayer(
        id: newLayerId,
        adjustmentKind: AdjustmentKind.aiDenoise,
      ),
      presetName: 'Denoise (AI)',
    );
    return newLayerId;
  }

  /// Phase XVI.66a — AI sharpen (NAFNet deblur). Same stateless
  /// ORT-only contract as [applyAiDenoise]. Throws
  /// [AiSharpenException] on inference failure.
  Future<String> applyAiSharpen({
    required AiSharpenService service,
    required String newLayerId,
  }) async {
    final cutoutImage = await runInference(
      logTag: 'applyAiSharpen',
      layerId: newLayerId,
      infer: () => service.sharpenFromPath(sourcePath),
      rethrowTyped: (e) => e is AiSharpenException,
      makeException: AiSharpenException.new,
    );
    cacheCutoutImage(newLayerId, cutoutImage);
    commitAdjustmentLayer(
      layer: AdjustmentLayer(
        id: newLayerId,
        adjustmentKind: AdjustmentKind.aiSharpen,
      ),
      presetName: 'Sharpen (AI)',
    );
    return newLayerId;
  }

  /// Phase XVI.66a — AI face restoration (RestoreFormer++). The
  /// service owns its own [FaceDetectionService] (it crops per face
  /// + pastes back so it can't share preloaded landmarks with the
  /// portrait-beauty cache without internal restructuring). Apply
  /// shape mirrors [applyEnhance]: stateless from the coordinator's
  /// perspective. Throws [FaceRestoreException] on inference
  /// failure.
  Future<String> applyFaceRestore({
    required FaceRestoreService service,
    required String newLayerId,
  }) async {
    final cutoutImage = await runInference(
      logTag: 'applyFaceRestore',
      layerId: newLayerId,
      infer: () => service.restoreFromPath(sourcePath),
      rethrowTyped: (e) => e is FaceRestoreException,
      makeException: FaceRestoreException.new,
    );
    cacheCutoutImage(newLayerId, cutoutImage);
    commitAdjustmentLayer(
      layer: AdjustmentLayer(
        id: newLayerId,
        adjustmentKind: AdjustmentKind.aiFaceRestore,
      ),
      presetName: 'Restore Faces',
    );
    return newLayerId;
  }

  /// Phase XV.2: run selfie-multiclass segmentation + LAB a*/b*
  /// recolour for hair / clothes / accessories. The [service]
  /// owns its LiteRT session; the caller disposes it after.
  Future<String> applyHairClothesRecolour({
    required HairClothesRecolourService service,
    required Set<int> classes,
    required int targetR,
    required int targetG,
    required int targetB,
    required String presetName,
    required String newLayerId,
  }) async {
    final cutoutImage = await runInference(
      logTag: 'applyHairClothesRecolour',
      layerId: newLayerId,
      infer: () => service.recolourFromPath(
        sourcePath: sourcePath,
        classes: classes,
        targetR: targetR,
        targetG: targetG,
        targetB: targetB,
      ),
      rethrowTyped: (e) => e is HairClothesRecolourException,
      makeException: HairClothesRecolourException.new,
      extraLogData: {
        'classes': classes.toList(),
        'rgb': [targetR, targetG, targetB],
      },
    );
    cacheCutoutImage(newLayerId, cutoutImage);
    commitAdjustmentLayer(
      layer: AdjustmentLayer(
        id: newLayerId,
        adjustmentKind: AdjustmentKind.hairClothesRecolour,
      ),
      presetName: presetName,
    );
    return newLayerId;
  }

  /// Phase XVI.47: multi-target hair-AND-clothes recolour in one
  /// segmentation inference. The pre-XVI.47 single-target path runs
  /// the model twice when both hair and clothes need recolouring; this
  /// call bundles both shifts into one pass for a ~2× speedup on the
  /// dominant cost (segmentation inference).
  ///
  /// Order in [targets] matters only when class sets overlap (rare
  /// since argmax keeps them disjoint at segmentation resolution).
  Future<String> applyHairClothesMultiRecolour({
    required HairClothesRecolourService service,
    required List<RecolourTarget> targets,
    required String presetName,
    required String newLayerId,
  }) async {
    final cutoutImage = await runInference(
      logTag: 'applyHairClothesMultiRecolour',
      layerId: newLayerId,
      infer: () => service.recolourMultipleFromPath(
        sourcePath: sourcePath,
        targets: targets,
      ),
      rethrowTyped: (e) => e is HairClothesRecolourException,
      makeException: HairClothesRecolourException.new,
      extraLogData: {
        'targets': targets.length,
        'classes': targets.map((t) => t.classes.toList()).toList(),
      },
    );
    cacheCutoutImage(newLayerId, cutoutImage);
    commitAdjustmentLayer(
      layer: AdjustmentLayer(
        id: newLayerId,
        adjustmentKind: AdjustmentKind.hairClothesRecolour,
      ),
      presetName: presetName,
    );
    return newLayerId;
  }

  /// Phase XVI.11: compose the matted subject onto a user-picked
  /// new background and ship TWO layers atomically — the opaque bg
  /// layer and the transformable subject layer — so the user can
  /// drag / scale / rotate the subject without re-running the
  /// matte.
  ///
  /// The halo fix sits in the compose service (zero-α RGB wipe);
  /// this coordinator method just orchestrates.
  Future<({String bgId, String subjectId})> applyComposeOnBackground({
    required ComposeOnBackgroundService service,
    required String backgroundPath,
    required String bgLayerId,
    required String subjectLayerId,
  }) async {
    if (_disposed) {
      throw const ComposeOnBackgroundException('Session is disposed');
    }
    final sw = Stopwatch()..start();
    _log.i('applyComposeOnBackground start', {
      'bgId': bgLayerId,
      'subjectId': subjectLayerId,
      'bgPath': backgroundPath,
    });
    ComposeResult result;
    try {
      result = await service.composeFromPaths(
        sourcePath: sourcePath,
        backgroundPath: backgroundPath,
      );
    } on ComposeOnBackgroundException {
      rethrow;
    } catch (e, st) {
      sw.stop();
      _log.e('applyComposeOnBackground service crashed',
          error: e, stackTrace: st, data: {'ms': sw.elapsedMilliseconds});
      throw ComposeOnBackgroundException(e.toString());
    }
    if (_disposed) {
      sw.stop();
      _log.w('applyComposeOnBackground aborted — session disposed',
          {'ms': sw.elapsedMilliseconds});
      result.background.dispose();
      result.subject.dispose();
      throw const ComposeOnBackgroundException(
        'Session closed during inference',
      );
    }
    sw.stop();
    _log.d('applyComposeOnBackground inference complete',
        {'ms': sw.elapsedMilliseconds});
    cacheCutoutImage(bgLayerId, result.background);
    cacheCutoutImage(subjectLayerId, result.subject);
    _composeSubjectRaw[subjectLayerId] = _ComposeSubjectRaw(
      rgba: result.subjectRawRgba,
      width: result.width,
      height: result.height,
    );
    commitAdjustmentLayerPair(
      first: AdjustmentLayer(
        id: bgLayerId,
        adjustmentKind: AdjustmentKind.composeOnBackground,
      ),
      second: AdjustmentLayer(
        id: subjectLayerId,
        adjustmentKind: AdjustmentKind.composeSubject,
      ),
      presetName: 'Compose on new background',
    );
    return (bgId: bgLayerId, subjectId: subjectLayerId);
  }

  /// Run face detection via [detectFaces] and, on
  /// [FaceDetectionException], wrap as [E] with a
  /// `"Face detection failed: …"` message that preserves the original
  /// exception in the typed `cause` channel. Kept private to the
  /// coordinator because only the 4 beauty methods share this
  /// pre-inference pattern.
  Future<List<DetectedFace>> _detectFacesOrThrow<E extends Object>(
    FaceDetectionService detector,
    E Function(String message, Object? cause) wrap,
  ) async {
    try {
      return await detectFaces(detector);
    } on FaceDetectionException catch (e) {
      throw wrap('Face detection failed: ${e.message}', e);
    }
  }

  /// True once [dispose] has been called. Subsequent [cacheCutoutImage]
  /// / [runInference] / [hydrate] calls all gate on this.
  @visibleForTesting
  bool get isDisposed => _disposed;

  /// Phase XVI.15 — re-bake the cached compose-subject image for
  /// [layerId] with the given edge-refine parameters and swap the
  /// [cutoutImageFor] cache entry. Returns `true` if the cache was
  /// updated, `false` if the layer has no cached raw bytes (fresh
  /// session after reload — the refine will remain approximate via
  /// the persisted baked image only).
  ///
  /// Caller is responsible for updating the pipeline op's
  /// parameters so the next [rebakeComposeSubjectEdges] starts from
  /// a consistent state. This method does NOT mutate the pipeline —
  /// it only touches the bitmap cache.
  Future<bool> rebakeComposeSubjectEdges({
    required String layerId,
    required double featherPx,
  }) async {
    if (_disposed) return false;
    final raw = _composeSubjectRaw[layerId];
    if (raw == null) {
      _log.d('rebake: no raw bytes cached', {'id': layerId});
      return false;
    }
    final sw = Stopwatch()..start();
    final baked = ComposeEdgeRefine.apply(
      straightRgba: raw.rgba,
      width: raw.width,
      height: raw.height,
      featherPx: featherPx,
    );
    final image = await BgRemovalImageIo.encodeRgbaToUiImage(
      rgba: baked,
      width: raw.width,
      height: raw.height,
    );
    sw.stop();
    if (_disposed) {
      image.dispose();
      return false;
    }
    _log.d('rebake complete', {
      'id': layerId,
      'featherPx': featherPx,
      'ms': sw.elapsedMilliseconds,
    });
    cacheCutoutImage(layerId, image);
    return true;
  }

  /// Phase XVI.15 — true if we still hold the raw subject bytes for
  /// [layerId] (i.e. the user is in the same session that produced
  /// the compose; post-reload this returns false). The UI uses this
  /// to decide whether edge-refine sliders can operate at full
  /// fidelity or should show a "re-run compose to refine edges"
  /// hint.
  bool hasComposeSubjectRaw(String layerId) =>
      _composeSubjectRaw.containsKey(layerId);

  /// Free every cached bitmap + halt pending persist/hydrate calls.
  /// Idempotent — double-dispose is safe.
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    for (final img in _cutoutImages.values) {
      img.dispose();
    }
    _cutoutImages.clear();
    _composeSubjectRaw.clear();
    _cutoutGen.clear();
    _log.d('disposed', {'cachedAtDispose': 0});
  }
}

/// Phase XVI.15 — private struct holding the straight-alpha subject
/// bytes that [AiCoordinator] feeds into [ComposeEdgeRefine.apply].
class _ComposeSubjectRaw {
  const _ComposeSubjectRaw({
    required this.rgba,
    required this.width,
    required this.height,
  });

  final Uint8List rgba;
  final int width;
  final int height;
}
