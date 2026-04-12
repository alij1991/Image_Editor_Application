import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import '../../../../core/logging/app_logger.dart';
import '../../../../engine/history/history_bloc.dart';
import '../../../../engine/history/history_event.dart';
import '../../../../engine/history/history_manager.dart';
import '../../../../engine/history/history_state.dart';
import '../../../../ai/services/bg_removal/bg_removal_strategy.dart';
import '../../../../ai/services/portrait_beauty/eye_brighten_service.dart';
import '../../../../ai/services/portrait_beauty/face_reshape_service.dart';
import '../../../../ai/services/portrait_beauty/portrait_smooth_service.dart';
import '../../../../ai/services/portrait_beauty/teeth_whiten_service.dart';
import '../../../../ai/services/sky_replace/sky_preset.dart';
import '../../../../ai/services/sky_replace/sky_replace_service.dart';
import '../../../../engine/history/memento_store.dart';
import '../../../../engine/layers/content_layer.dart';
import '../../../../engine/pipeline/edit_op_type.dart';
import '../../../../engine/pipeline/edit_operation.dart';
import '../../../../engine/pipeline/edit_pipeline.dart';
import '../../../../engine/pipeline/matrix_composer.dart';
import '../../../../engine/pipeline/op_spec.dart';
import '../../../../engine/pipeline/pipeline_extensions.dart';
import '../../../../engine/pipeline/preview_proxy.dart';
import '../../../../engine/presets/preset.dart';
import '../../../../engine/presets/preset_applier.dart';
import '../../../../engine/rendering/shader_pass.dart';
import '../../../../engine/rendering/shaders/color_grading_shader.dart';
import '../../../../engine/rendering/shaders/effect_shaders.dart';
import '../../../../engine/rendering/shaders/tonal_shaders.dart';
import 'preview_controller.dart';

final _log = AppLogger('EditorSession');

/// A live editing session bound to one preview proxy.
///
/// Owns:
///   - the [PreviewProxy] that holds the decoded `ui.Image`
///   - the [HistoryManager] / [HistoryBloc] that tracks undo/redo
///   - the [PreviewController] that slider widgets talk to directly
///
/// Two state feedback paths:
///
///  Imperative (hot path):
///    Slider → setScalar → rebuildPreview → previewController.setPasses
///    → ValueNotifier notifies → CustomPaint repaints. No widget rebuild.
///
///  Declarative (cold path):
///    HistoryBloc emits (after commit / undo / redo) → [_onHistoryStateChanged]
///    → rebuildPreview(). This catches undo/redo where the pipeline changes
///    without going through setScalar.
class EditorSession {
  EditorSession._({
    required this.sourcePath,
    required this.proxy,
    required this.historyManager,
    required this.historyBloc,
    required this.previewController,
    required this.mementoStore,
  });

  static Future<EditorSession> start({
    required String sourcePath,
    required PreviewProxy proxy,
  }) async {
    _log.i('start', {'path': sourcePath});
    final mementoStore = MementoStore();
    await mementoStore.init();
    _log.d('memento store init complete');

    final history = HistoryManager.withPipeline(
      mementoStore: mementoStore,
      initial: EditPipeline.forOriginal(sourcePath),
    );
    final bloc = HistoryBloc(manager: history);

    late EditorSession session;
    final preview = PreviewController(
      onCommit: (pipeline) => session._commitPipeline(pipeline),
    );
    session = EditorSession._(
      sourcePath: sourcePath,
      proxy: proxy,
      historyManager: history,
      historyBloc: bloc,
      previewController: preview,
      mementoStore: mementoStore,
    );
    session._historySub = bloc.stream.listen(session._onHistoryStateChanged);
    _log.i('session ready', {
      'imageW': proxy.image?.width,
      'imageH': proxy.image?.height,
    });
    return session;
  }

  final String sourcePath;
  final PreviewProxy proxy;
  final HistoryManager historyManager;
  final HistoryBloc historyBloc;
  final PreviewController previewController;
  final MementoStore mementoStore;

  static const MatrixComposer _composer = MatrixComposer();

  /// Working pipeline during an uncommitted drag. Reset after each commit
  /// and whenever history changes externally (undo/redo).
  EditPipeline _workingPipeline = EditPipeline.forOriginal('');

  /// Per-op-type id cache. When the user drags the same slider repeatedly
  /// we reuse the op id so the history stays a single entry per commit.
  final Map<String, String> _opIds = {};

  /// The op-type of the most-recently modified op. Used by
  /// [_commitPipeline] so a commit pushes the correct op through the bloc.
  String? _lastTouchedType;

  /// Volatile cutout bitmaps for [AdjustmentLayer]s, keyed by layer id.
  /// These are the result of AI segmentation and are NOT persisted with
  /// the pipeline. Entries are kept for the lifetime of the session so
  /// that undo/redo across a BG-removal op preserves the AI output —
  /// evicting on history change would make redo lose the cutout, since
  /// the pipeline only stores metadata. Freed in [dispose] or replaced
  /// via [_cacheCutoutImage] when the same id is re-segmented.
  final Map<String, ui.Image> _cutoutImages = {};

  StreamSubscription<HistoryState>? _historySub;
  bool _disposed = false;

  ui.Image get sourceImage {
    final img = proxy.image;
    if (img == null) {
      throw StateError('EditorSession used before proxy was loaded');
    }
    return img;
  }

  EditPipeline get workingPipeline =>
      _workingPipeline.operations.isEmpty
          ? historyManager.currentPipeline
          : _workingPipeline;

  EditPipeline get committedPipeline => historyManager.currentPipeline;

  // ----- Public mutation API -------------------------------------------------

  /// Set a single scalar parameter. For single-param ops (brightness,
  /// contrast, ...) [paramKey] defaults to `'value'`. For multi-param ops
  /// (vignette amount/feather/roundness) pass the explicit sub-param key.
  ///
  /// If **all** the op's parameters return to identity, the op is removed
  /// from the pipeline so the shader chain stays short.
  void setScalar(String type, double value, {String paramKey = 'value'}) {
    if (_disposed) return;
    // Merge with existing params so multi-param ops preserve siblings.
    final existing = committedPipeline.findOp(type);
    final merged = <String, dynamic>{
      ...?existing?.parameters,
      paramKey: value,
    };
    final specs = OpSpecs.paramsForType(type);
    final allIdentity = specs.isNotEmpty &&
        specs.every((spec) {
          final raw = merged[spec.paramKey];
          final v = raw is num ? raw.toDouble() : spec.identity;
          return spec.isIdentity(v);
        });
    _log.d('setScalar', {
      'type': type,
      'paramKey': paramKey,
      'value': value,
      'identity': allIdentity,
    });
    _applyEdit(
      type: type,
      params: merged,
      removeIfPresent: allIdentity,
    );
  }

  /// Set a multi-param op (levels, split toning, HSL, tone curve). The
  /// caller is responsible for identity semantics — a map op is only
  /// removed if [removeIfIdentity] is true.
  void setMapParams(
    String type,
    Map<String, dynamic> params, {
    bool removeIfIdentity = false,
  }) {
    if (_disposed) return;
    _log.d('setMapParams', {'type': type, 'keys': params.keys.toList()});
    _applyEdit(
      type: type,
      params: params,
      removeIfPresent: removeIfIdentity,
    );
  }

  void _applyEdit({
    required String type,
    required Map<String, dynamic> params,
    required bool removeIfPresent,
  }) {
    final base = committedPipeline;
    final existingId = _opIds[type];

    EditPipeline next;
    bool isNoOp = false;
    if (removeIfPresent) {
      // Drop the op entirely so the shader chain doesn't include it.
      if (existingId != null &&
          base.operations.any((o) => o.id == existingId)) {
        next = base.remove(existingId);
      } else {
        // Nothing to do — user reset a slider that was never engaged.
        next = base;
        isNoOp = true;
      }
      _opIds.remove(type);
    } else {
      next = _upsertOp(base, type, id: existingId, parameters: params);
      final op = next.operations.firstWhere((o) => o.type == type);
      _opIds[type] = op.id;
    }

    _workingPipeline = next;
    _lastTouchedType = type;
    rebuildPreview();
    if (isNoOp) {
      // Don't schedule a commit for a reset that changed nothing; the
      // debounced handler would just emit an empty event and spam logs.
      _log.d('_applyEdit: no-op skipped', {'type': type});
      return;
    }
    previewController.scheduleCommit(next);
  }

  /// Flush any pending debounce (call on pointer up / slider release).
  void flushPendingCommit() {
    if (_disposed) return;
    _log.d('flushPendingCommit');
    previewController.flushCommit();
  }

  /// Toggle visibility of all edits (used by the tap-hold before/after
  /// preview). Does NOT go through the history — this is a transient view
  /// that snaps back when the tap is released.
  void setAllOpsEnabledTransient(bool enabled) {
    if (_disposed) return;
    _log.d('setAllOpsEnabledTransient', {'enabled': enabled});
    historyBloc.add(SetAllOpsEnabled(enabled));
  }

  // ----- Geometry mutators -------------------------------------------------

  /// Rotate by 90° in the given [direction] (+1 = CW, -1 = CCW).
  /// Updates the rotate op's `steps` param and commits immediately.
  void rotate90(int direction) {
    if (_disposed) return;
    final current = committedPipeline.geometryState.rotationStepsNormalized;
    final next = ((current + direction) % 4 + 4) % 4;
    _log.i('rotate90', {'direction': direction, 'from': current, 'to': next});
    _applyEdit(
      type: EditOpType.rotate,
      params: {'steps': next},
      removeIfPresent: next == 0,
    );
    previewController.flushCommit();
  }

  /// Toggle horizontal flip. Commits immediately.
  void toggleFlipH() {
    if (_disposed) return;
    final state = committedPipeline.geometryState;
    final nextH = !state.flipH;
    _log.i('toggleFlipH', {'to': nextH});
    _applyEdit(
      type: EditOpType.flip,
      params: {'h': nextH, 'v': state.flipV},
      removeIfPresent: !nextH && !state.flipV,
    );
    previewController.flushCommit();
  }

  /// Toggle vertical flip. Commits immediately.
  void toggleFlipV() {
    if (_disposed) return;
    final state = committedPipeline.geometryState;
    final nextV = !state.flipV;
    _log.i('toggleFlipV', {'to': nextV});
    _applyEdit(
      type: EditOpType.flip,
      params: {'h': state.flipH, 'v': nextV},
      removeIfPresent: !state.flipH && !nextV,
    );
    previewController.flushCommit();
  }

  /// Set (or clear) the crop aspect-ratio metadata. The actual crop
  /// rect UI ships in a later phase; this stores the user intent so the
  /// chip in the geometry panel stays selected across sessions.
  void setCropAspectRatio(double? ratio) {
    if (_disposed) return;
    _log.i('setCropAspectRatio', {'ratio': ratio});
    _applyEdit(
      type: EditOpType.crop,
      params: {'aspectRatio': ratio},
      removeIfPresent: ratio == null,
    );
    previewController.flushCommit();
  }

  // ----- Content layer mutators --------------------------------------------

  /// Append a new [ContentLayer] to the pipeline. Returns the assigned
  /// op id so the caller can immediately update / delete the layer
  /// without re-querying the pipeline.
  ///
  /// Layer op types are NOT written to [_opIds] because there can be
  /// multiple layers of the same kind; the cache only holds the last
  /// one and becomes misleading. Layer mutations always look up by
  /// the layer's own id.
  String addLayer(ContentLayer layer) {
    if (_disposed) return '';
    final opType = opTypeForLayerKind(layer.kind);
    final op = EditOperation.create(
      type: opType,
      parameters: layer.toParams(),
      enabled: layer.visible,
    );
    _log.i('addLayer', {
      'kind': layer.kind.name,
      'id': op.id,
      'label': layer.displayLabel,
    });
    final next = committedPipeline.append(op);
    historyBloc.add(
      ApplyPresetEvent(pipeline: next, presetName: 'Add ${layer.kind.name}'),
    );
    return op.id;
  }

  /// Replace the parameters of an existing content layer identified by
  /// its [layer.id]. Commits immediately via [ExecuteEdit] so sliders
  /// in the layer panel feel snappy.
  void updateLayer(ContentLayer layer) {
    if (_disposed) return;
    final current = committedPipeline.findById(layer.id);
    if (current == null) {
      _log.w('updateLayer: id not found', {'id': layer.id});
      return;
    }
    _log.d('updateLayer', {
      'id': layer.id,
      'kind': layer.kind.name,
      'visible': layer.visible,
    });
    historyBloc.add(
      ExecuteEdit(
        op: current.copyWith(
          parameters: layer.toParams(),
          enabled: layer.visible,
        ),
        afterParameters: layer.toParams(),
      ),
    );
  }

  /// Remove a content layer by id.
  void deleteLayer(String layerId) {
    if (_disposed) return;
    final current = committedPipeline.findById(layerId);
    if (current == null) {
      _log.w('deleteLayer: id not found', {'id': layerId});
      return;
    }
    _log.i('deleteLayer', {'id': layerId, 'type': current.type});
    final next = committedPipeline.remove(layerId);
    historyBloc.add(
      ApplyPresetEvent(pipeline: next, presetName: 'Delete layer'),
    );
  }

  /// Toggle a layer's visibility without recording a parameter change.
  /// Reads better in the layer panel than a full ExecuteEdit because
  /// only the enabled flag flips.
  void toggleLayerVisibility(String layerId) {
    if (_disposed) return;
    _log.i('toggleLayerVisibility', {'id': layerId});
    historyBloc.add(ToggleOpEnabled(layerId));
  }

  /// Ephemeral layer update that does NOT go through history. Used for
  /// live previews during slider drags in the layer edit sheet or the
  /// opacity slider in the layer stack tile. The preview bypasses the
  /// pipeline and writes directly to [PreviewController.layers] so the
  /// canvas updates at 60 fps without spamming history entries.
  ///
  /// Call [cancelLayerPreview] to revert, or [updateLayer] to commit.
  void previewLayer(ContentLayer layer) {
    if (_disposed) return;
    _log.d('previewLayer', {'id': layer.id, 'kind': layer.kind.name});
    // Build a layer list from the committed pipeline with this layer
    // swapped in. Hidden layers are skipped because the preview list
    // only contains what the canvas should render.
    final layers = <ContentLayer>[];
    for (final op in committedPipeline.operations) {
      final parsed = contentLayerFromOp(op);
      if (parsed == null) continue;
      if (parsed.id == layer.id) {
        if (!layer.visible) continue;
        layers.add(layer);
      } else {
        if (parsed.visible) layers.add(parsed);
      }
    }
    previewController.setLayers(layers);
  }

  /// Clear any ephemeral preview and re-derive layers from the
  /// committed pipeline. Called when the user cancels a layer edit.
  void cancelLayerPreview() {
    if (_disposed) return;
    _log.d('cancelLayerPreview');
    rebuildPreview();
  }

  /// Move a layer to a new position in the layer stack.
  /// [newLayerIndex] is 0-based in PAINT ORDER (bottom-most = 0,
  /// top-most = N-1) so non-layer ops (color / geometry) keep their
  /// original positions in the pipeline.
  void reorderLayer(String layerId, int newLayerIndex) {
    if (_disposed) return;
    _log.i('reorderLayer',
        {'id': layerId, 'targetLayerIndex': newLayerIndex});
    final next = committedPipeline.reorderLayers(
      layerId: layerId,
      newLayerIndex: newLayerIndex,
      isLayer: (op) =>
          op.type == EditOpType.text ||
          op.type == EditOpType.sticker ||
          op.type == EditOpType.drawing ||
          op.type == EditOpType.adjustmentLayer,
    );
    if (identical(next, committedPipeline)) {
      _log.d('reorderLayer: no-op');
      return;
    }
    historyBloc.add(
      ApplyPresetEvent(pipeline: next, presetName: 'Reorder layer'),
    );
  }

  // ----- AI features --------------------------------------------------------

  /// Run background removal via the given [strategy] (MediaPipe,
  /// MODNet, or RMBG), cache the resulting cutout image, and append a
  /// new [AdjustmentLayer] to the pipeline.
  ///
  /// Throws [BgRemovalException] on inference failure so the UI can
  /// show a typed error. Returns the new layer id on success.
  ///
  /// Session-level logs here are deliberately verbose — AI failures
  /// are the hardest thing to debug once shipped, so every success +
  /// failure branch emits a `layerId`-tagged entry so logs can be
  /// grouped by "which invocation went wrong".
  Future<String> applyBackgroundRemoval({
    required BgRemovalStrategy strategy,
    required String newLayerId,
  }) async {
    if (_disposed) {
      _log.w('applyBackgroundRemoval rejected — session disposed', {
        'layerId': newLayerId,
        'strategy': strategy.kind.name,
      });
      throw BgRemovalException(
        'Session is disposed',
        kind: strategy.kind,
      );
    }
    final sw = Stopwatch()..start();
    _log.i('applyBackgroundRemoval start', {
      'layerId': newLayerId,
      'strategy': strategy.kind.name,
      'sourcePath': sourcePath,
    });
    final ui.Image cutoutImage;
    try {
      cutoutImage = await strategy.removeBackgroundFromPath(sourcePath);
    } on BgRemovalException catch (e) {
      sw.stop();
      _log.w('applyBackgroundRemoval strategy failed', {
        'layerId': newLayerId,
        'strategy': strategy.kind.name,
        'ms': sw.elapsedMilliseconds,
        'message': e.message,
      });
      rethrow;
    } catch (e, st) {
      sw.stop();
      _log.e('applyBackgroundRemoval strategy crashed',
          error: e,
          stackTrace: st,
          data: {
            'layerId': newLayerId,
            'strategy': strategy.kind.name,
            'ms': sw.elapsedMilliseconds,
          });
      throw BgRemovalException(
        e.toString(),
        kind: strategy.kind,
      );
    }

    // Disposal race guard: the session may have been closed while
    // inference was running. Drop the orphaned image and bail cleanly
    // instead of writing to a closed historyBloc or leaking GPU
    // memory.
    if (_disposed) {
      sw.stop();
      _log.w('applyBackgroundRemoval aborted — session disposed during inference', {
        'layerId': newLayerId,
        'strategy': strategy.kind.name,
        'ms': sw.elapsedMilliseconds,
      });
      cutoutImage.dispose();
      throw BgRemovalException(
        'Session closed during inference',
        kind: strategy.kind,
      );
    }

    // Cache the volatile ui.Image before we push the op through the
    // bloc. rebuildPreview reads from this cache to fill in the
    // AdjustmentLayer's `cutoutImage` field when the history state
    // change fires.
    _cacheCutoutImage(newLayerId, cutoutImage);

    // Build the op with the pre-assigned id so the cache key stays
    // in sync. `toParams()` does NOT include the volatile
    // `cutoutImage` — the cache is the authoritative store.
    const layer = AdjustmentLayer(
      id: '', // placeholder; replaced via copyWith(id) below
      adjustmentKind: AdjustmentKind.backgroundRemoval,
    );
    final op = EditOperation.create(
      type: EditOpType.adjustmentLayer,
      parameters: layer.toParams(),
    ).copyWith(id: newLayerId);
    final next = committedPipeline.append(op);
    historyBloc.add(
      ApplyPresetEvent(
        pipeline: next,
        presetName: 'Remove background',
      ),
    );
    sw.stop();
    _log.i('applyBackgroundRemoval committed', {
      'layerId': newLayerId,
      'strategy': strategy.kind.name,
      'totalMs': sw.elapsedMilliseconds,
      'cutoutW': cutoutImage.width,
      'cutoutH': cutoutImage.height,
    });
    return newLayerId;
  }

  /// Phase 9d: run face detection + portrait smoothing via [service],
  /// cache the resulting bitmap, and append a new [AdjustmentLayer]
  /// of kind [AdjustmentKind.portraitSmooth] to the pipeline.
  ///
  /// Mirrors [applyBackgroundRemoval]'s lifecycle: disposal guards
  /// before + after the inference await, per-invocation timing log,
  /// and a typed exception bubble-up so the editor page can show a
  /// coaching message when no face is detected.
  Future<String> applyPortraitSmooth({
    required PortraitSmoothService service,
    required String newLayerId,
  }) async {
    if (_disposed) {
      _log.w('applyPortraitSmooth rejected — session disposed',
          {'layerId': newLayerId});
      throw const PortraitSmoothException('Session is disposed');
    }
    final sw = Stopwatch()..start();
    _log.i('applyPortraitSmooth start', {
      'layerId': newLayerId,
      'sourcePath': sourcePath,
    });
    final ui.Image cutoutImage;
    try {
      cutoutImage = await service.smoothFromPath(sourcePath);
    } on PortraitSmoothException catch (e) {
      sw.stop();
      _log.w('applyPortraitSmooth service failed', {
        'layerId': newLayerId,
        'ms': sw.elapsedMilliseconds,
        'message': e.message,
      });
      rethrow;
    } catch (e, st) {
      sw.stop();
      _log.e('applyPortraitSmooth service crashed',
          error: e,
          stackTrace: st,
          data: {
            'layerId': newLayerId,
            'ms': sw.elapsedMilliseconds,
          });
      throw PortraitSmoothException(e.toString());
    }

    if (_disposed) {
      sw.stop();
      _log.w('applyPortraitSmooth aborted — session disposed during inference',
          {'layerId': newLayerId, 'ms': sw.elapsedMilliseconds});
      cutoutImage.dispose();
      throw const PortraitSmoothException(
        'Session closed during inference',
      );
    }

    _cacheCutoutImage(newLayerId, cutoutImage);

    const layer = AdjustmentLayer(
      id: '',
      adjustmentKind: AdjustmentKind.portraitSmooth,
    );
    final op = EditOperation.create(
      type: EditOpType.adjustmentLayer,
      parameters: layer.toParams(),
    ).copyWith(id: newLayerId);
    final next = committedPipeline.append(op);
    historyBloc.add(
      ApplyPresetEvent(
        pipeline: next,
        presetName: 'Smooth skin',
      ),
    );
    sw.stop();
    _log.i('applyPortraitSmooth committed', {
      'layerId': newLayerId,
      'totalMs': sw.elapsedMilliseconds,
      'cutoutW': cutoutImage.width,
      'cutoutH': cutoutImage.height,
    });
    return newLayerId;
  }

  /// Phase 9e: detect faces, brighten pixels inside soft circles at
  /// each eye landmark, cache the result, and append a new
  /// [AdjustmentLayer] of kind [AdjustmentKind.eyeBrighten].
  ///
  /// Lifecycle mirrors [applyBackgroundRemoval] + [applyPortraitSmooth]
  /// exactly: pre-await disposal guard, post-await disposal race guard
  /// with cutout dispose, three log branches (`'service failed'`,
  /// `'service crashed'`, `'committed'`), and layerId-tagged entries
  /// so a post-hoc grep gives the full trace.
  Future<String> applyEyeBrighten({
    required EyeBrightenService service,
    required String newLayerId,
  }) async {
    if (_disposed) {
      _log.w('applyEyeBrighten rejected — session disposed',
          {'layerId': newLayerId});
      throw const EyeBrightenException('Session is disposed');
    }
    final sw = Stopwatch()..start();
    _log.i('applyEyeBrighten start', {
      'layerId': newLayerId,
      'sourcePath': sourcePath,
    });
    final ui.Image cutoutImage;
    try {
      cutoutImage = await service.brightenFromPath(sourcePath);
    } on EyeBrightenException catch (e) {
      sw.stop();
      _log.w('applyEyeBrighten service failed', {
        'layerId': newLayerId,
        'ms': sw.elapsedMilliseconds,
        'message': e.message,
      });
      rethrow;
    } catch (e, st) {
      sw.stop();
      _log.e('applyEyeBrighten service crashed',
          error: e,
          stackTrace: st,
          data: {'layerId': newLayerId, 'ms': sw.elapsedMilliseconds});
      throw EyeBrightenException(e.toString());
    }

    if (_disposed) {
      sw.stop();
      _log.w(
          'applyEyeBrighten aborted — session disposed during inference',
          {'layerId': newLayerId, 'ms': sw.elapsedMilliseconds});
      cutoutImage.dispose();
      throw const EyeBrightenException(
        'Session closed during inference',
      );
    }

    _cacheCutoutImage(newLayerId, cutoutImage);

    const layer = AdjustmentLayer(
      id: '',
      adjustmentKind: AdjustmentKind.eyeBrighten,
    );
    final op = EditOperation.create(
      type: EditOpType.adjustmentLayer,
      parameters: layer.toParams(),
    ).copyWith(id: newLayerId);
    final next = committedPipeline.append(op);
    historyBloc.add(
      ApplyPresetEvent(
        pipeline: next,
        presetName: 'Brighten eyes',
      ),
    );
    sw.stop();
    _log.i('applyEyeBrighten committed', {
      'layerId': newLayerId,
      'totalMs': sw.elapsedMilliseconds,
      'cutoutW': cutoutImage.width,
      'cutoutH': cutoutImage.height,
    });
    return newLayerId;
  }

  /// Phase 9e: detect faces, whiten pixels inside a soft circle at
  /// the mouth center, cache the result, and append a new
  /// [AdjustmentLayer] of kind [AdjustmentKind.teethWhiten].
  Future<String> applyTeethWhiten({
    required TeethWhitenService service,
    required String newLayerId,
  }) async {
    if (_disposed) {
      _log.w('applyTeethWhiten rejected — session disposed',
          {'layerId': newLayerId});
      throw const TeethWhitenException('Session is disposed');
    }
    final sw = Stopwatch()..start();
    _log.i('applyTeethWhiten start', {
      'layerId': newLayerId,
      'sourcePath': sourcePath,
    });
    final ui.Image cutoutImage;
    try {
      cutoutImage = await service.whitenFromPath(sourcePath);
    } on TeethWhitenException catch (e) {
      sw.stop();
      _log.w('applyTeethWhiten service failed', {
        'layerId': newLayerId,
        'ms': sw.elapsedMilliseconds,
        'message': e.message,
      });
      rethrow;
    } catch (e, st) {
      sw.stop();
      _log.e('applyTeethWhiten service crashed',
          error: e,
          stackTrace: st,
          data: {'layerId': newLayerId, 'ms': sw.elapsedMilliseconds});
      throw TeethWhitenException(e.toString());
    }

    if (_disposed) {
      sw.stop();
      _log.w(
          'applyTeethWhiten aborted — session disposed during inference',
          {'layerId': newLayerId, 'ms': sw.elapsedMilliseconds});
      cutoutImage.dispose();
      throw const TeethWhitenException(
        'Session closed during inference',
      );
    }

    _cacheCutoutImage(newLayerId, cutoutImage);

    const layer = AdjustmentLayer(
      id: '',
      adjustmentKind: AdjustmentKind.teethWhiten,
    );
    final op = EditOperation.create(
      type: EditOpType.adjustmentLayer,
      parameters: layer.toParams(),
    ).copyWith(id: newLayerId);
    final next = committedPipeline.append(op);
    historyBloc.add(
      ApplyPresetEvent(
        pipeline: next,
        presetName: 'Whiten teeth',
      ),
    );
    sw.stop();
    _log.i('applyTeethWhiten committed', {
      'layerId': newLayerId,
      'totalMs': sw.elapsedMilliseconds,
      'cutoutW': cutoutImage.width,
      'cutoutH': cutoutImage.height,
    });
    return newLayerId;
  }

  /// Phase 9f: run face contour detection + warp-based reshape
  /// via [service], cache the resulting bitmap, and append a new
  /// [AdjustmentLayer] of kind [AdjustmentKind.faceReshape].
  ///
  /// Lifecycle mirrors the other beauty methods: pre-await
  /// disposal guard, post-await disposal race guard with cutout
  /// dispose, three log branches (`'service failed'`, `'service
  /// crashed'`, `'committed'`), and `layerId`-tagged entries.
  ///
  /// Unlike the other beauty ops, this method also records the
  /// reshape strengths on the layer so a future reload can
  /// re-run the warp without having to guess which preset was
  /// used. Pass an explicit [reshapeParams] map from the caller;
  /// the session itself doesn't know what the tuning knobs mean.
  Future<String> applyFaceReshape({
    required FaceReshapeService service,
    required String newLayerId,
    required Map<String, double> reshapeParams,
  }) async {
    if (_disposed) {
      _log.w('applyFaceReshape rejected — session disposed',
          {'layerId': newLayerId});
      throw const FaceReshapeException('Session is disposed');
    }
    final sw = Stopwatch()..start();
    _log.i('applyFaceReshape start', {
      'layerId': newLayerId,
      'sourcePath': sourcePath,
      'reshapeParams': reshapeParams,
    });
    final ui.Image cutoutImage;
    try {
      cutoutImage = await service.reshapeFromPath(sourcePath);
    } on FaceReshapeException catch (e) {
      sw.stop();
      _log.w('applyFaceReshape service failed', {
        'layerId': newLayerId,
        'ms': sw.elapsedMilliseconds,
        'message': e.message,
      });
      rethrow;
    } catch (e, st) {
      sw.stop();
      _log.e('applyFaceReshape service crashed',
          error: e,
          stackTrace: st,
          data: {'layerId': newLayerId, 'ms': sw.elapsedMilliseconds});
      throw FaceReshapeException(e.toString());
    }

    if (_disposed) {
      sw.stop();
      _log.w(
          'applyFaceReshape aborted — session disposed during inference',
          {'layerId': newLayerId, 'ms': sw.elapsedMilliseconds});
      cutoutImage.dispose();
      throw const FaceReshapeException(
        'Session closed during inference',
      );
    }

    _cacheCutoutImage(newLayerId, cutoutImage);

    final layer = AdjustmentLayer(
      id: '',
      adjustmentKind: AdjustmentKind.faceReshape,
      reshapeParams: Map<String, double>.unmodifiable(reshapeParams),
    );
    final op = EditOperation.create(
      type: EditOpType.adjustmentLayer,
      parameters: layer.toParams(),
    ).copyWith(id: newLayerId);
    final next = committedPipeline.append(op);
    historyBloc.add(
      ApplyPresetEvent(
        pipeline: next,
        presetName: 'Sculpt face',
      ),
    );
    sw.stop();
    _log.i('applyFaceReshape committed', {
      'layerId': newLayerId,
      'totalMs': sw.elapsedMilliseconds,
      'cutoutW': cutoutImage.width,
      'cutoutH': cutoutImage.height,
      'reshapeParams': reshapeParams,
    });
    return newLayerId;
  }

  /// Phase 9g: run heuristic sky segmentation + procedural sky
  /// replacement via [service], cache the resulting bitmap, and
  /// append a new [AdjustmentLayer] of kind
  /// [AdjustmentKind.skyReplace].
  ///
  /// [preset] is serialized onto the layer as `skyPresetName` so a
  /// future reload / Rust export can reproduce the swap with the
  /// same palette.
  ///
  /// Same lifecycle as [applyFaceReshape]: pre/post-await disposal
  /// guards, three log branches, layerId-tagged entries.
  Future<String> applySkyReplace({
    required SkyReplaceService service,
    required String newLayerId,
    required SkyPreset preset,
  }) async {
    if (_disposed) {
      _log.w('applySkyReplace rejected — session disposed',
          {'layerId': newLayerId});
      throw const SkyReplaceException('Session is disposed');
    }
    final sw = Stopwatch()..start();
    _log.i('applySkyReplace start', {
      'layerId': newLayerId,
      'sourcePath': sourcePath,
      'preset': preset.name,
    });
    final ui.Image cutoutImage;
    try {
      cutoutImage = await service.replaceSkyFromPath(
        sourcePath: sourcePath,
        preset: preset,
      );
    } on SkyReplaceException catch (e) {
      sw.stop();
      _log.w('applySkyReplace service failed', {
        'layerId': newLayerId,
        'ms': sw.elapsedMilliseconds,
        'message': e.message,
      });
      rethrow;
    } catch (e, st) {
      sw.stop();
      _log.e('applySkyReplace service crashed',
          error: e,
          stackTrace: st,
          data: {'layerId': newLayerId, 'ms': sw.elapsedMilliseconds});
      throw SkyReplaceException(e.toString());
    }

    if (_disposed) {
      sw.stop();
      _log.w(
          'applySkyReplace aborted — session disposed during inference',
          {'layerId': newLayerId, 'ms': sw.elapsedMilliseconds});
      cutoutImage.dispose();
      throw const SkyReplaceException(
        'Session closed during inference',
      );
    }

    _cacheCutoutImage(newLayerId, cutoutImage);

    final layer = AdjustmentLayer(
      id: '',
      adjustmentKind: AdjustmentKind.skyReplace,
      skyPresetName: preset.persistKey,
    );
    final op = EditOperation.create(
      type: EditOpType.adjustmentLayer,
      parameters: layer.toParams(),
    ).copyWith(id: newLayerId);
    final next = committedPipeline.append(op);
    historyBloc.add(
      ApplyPresetEvent(
        pipeline: next,
        presetName: 'Replace sky',
      ),
    );
    sw.stop();
    _log.i('applySkyReplace committed', {
      'layerId': newLayerId,
      'totalMs': sw.elapsedMilliseconds,
      'cutoutW': cutoutImage.width,
      'cutoutH': cutoutImage.height,
      'preset': preset.name,
    });
    return newLayerId;
  }

  // ----- Existing mutators --------------------------------------------------

  /// Drop every adjustment and go back to the original image. Recorded
  /// as a single history entry (via the preset apply path) so undo
  /// restores all the prior edits at once.
  void resetAll() {
    if (_disposed) return;
    _log.i('resetAll');
    historyBloc.add(
      ApplyPresetEvent(
        pipeline: EditPipeline.forOriginal(sourcePath),
        presetName: 'Reset',
      ),
    );
  }

  /// Stamp a [Preset] into the pipeline. Every op in the preset replaces
  /// any same-typed op in the pipeline (matching Lightroom's behavior).
  /// The result is committed as a single atomic history entry so undo
  /// reverts the whole preset in one step.
  void applyPreset(Preset preset) {
    if (_disposed) return;
    _log.i('applyPreset',
        {'name': preset.name, 'ops': preset.operations.length});
    const applier = PresetApplier();
    final next = applier.apply(preset, committedPipeline);
    // Fire the atomic preset event. The bloc handler commits the whole
    // pipeline as one history entry and emits a new state; our stream
    // subscription will pick it up and call rebuildPreview automatically.
    historyBloc.add(
      ApplyPresetEvent(pipeline: next, presetName: preset.name),
    );
  }

  // ----- Render path ---------------------------------------------------------

  /// Apply the current pipeline and push the resulting passes + geometry
  /// + content layers to the preview. Called when the session starts
  /// and after history changes.
  ///
  /// [AdjustmentLayer]s need special handling: the pipeline only stores
  /// metadata (the adjustment kind + layer id), and the volatile
  /// [AdjustmentLayer.cutoutImage] has to be filled in from
  /// [_cutoutImages] before handing the list to the preview
  /// controller.
  void rebuildPreview() {
    if (_disposed) return;
    final pipelineToRender = workingPipeline;
    final passes = _passesFor(pipelineToRender);
    final geometry = pipelineToRender.geometryState;
    final rawLayers = pipelineToRender.contentLayers;
    final layers = <ContentLayer>[];
    for (final layer in rawLayers) {
      if (layer is AdjustmentLayer) {
        final img = _cutoutImages[layer.id];
        // Skip adjustment layers whose cutout image isn't in cache
        // (e.g. a session reloaded from a persisted pipeline in a
        // future phase). Phase 12 will persist mementos.
        if (img == null) continue;
        layers.add(layer.copyWith(cutoutImage: img));
      } else {
        layers.add(layer);
      }
    }
    _log.d('rebuildPreview', {
      'ops': pipelineToRender.operations.length,
      'passes': passes.length,
      'geometry': geometry.toString(),
      'layers': layers.length,
      'cutouts': _cutoutImages.length,
    });
    previewController.setPasses(passes);
    previewController.setGeometry(geometry);
    previewController.setLayers(layers);
  }

  /// Store a decoded cutout image for an [AdjustmentLayer] id. Called
  /// when an AI feature produces a new mask. Any existing image for
  /// the same id is disposed first to avoid leaking GPU memory.
  void _cacheCutoutImage(String layerId, ui.Image image) {
    final prev = _cutoutImages.remove(layerId);
    prev?.dispose();
    _cutoutImages[layerId] = image;
    _log.d('cached cutout', {
      'id': layerId,
      'width': image.width,
      'height': image.height,
    });
  }

  List<ShaderPass> _passesFor(EditPipeline pipeline) {
    if (pipeline.operations.isEmpty) return const [];
    final passes = <ShaderPass>[];

    // Pass 1: composed color matrix + exposure + temperature + tint.
    // The matrix is zero-cost if no matrix ops are active (it's identity),
    // but we only add the pass when at least one of these is present.
    final hasMatrixOp = pipeline.operations.any(
      (o) => o.enabled && EditOpType.matrixComposable.contains(o.type),
    );
    final hasTempTintExposure = pipeline.hasEnabledOp(EditOpType.exposure) ||
        pipeline.hasEnabledOp(EditOpType.temperature) ||
        pipeline.hasEnabledOp(EditOpType.tint);
    if (hasMatrixOp || hasTempTintExposure) {
      final matrix = _composer.compose(pipeline);
      passes.add(
        ColorGradingShader(
          colorMatrix5x4: matrix,
          exposure: pipeline.exposureValue,
          temperature: pipeline.temperatureValue,
          tint: pipeline.tintValue,
        ).toPass(),
      );
    }

    // Pass 2: highlights / shadows / whites / blacks.
    final hasHS = pipeline.hasEnabledOp(EditOpType.highlights) ||
        pipeline.hasEnabledOp(EditOpType.shadows) ||
        pipeline.hasEnabledOp(EditOpType.whites) ||
        pipeline.hasEnabledOp(EditOpType.blacks);
    if (hasHS) {
      passes.add(
        HighlightsShadowsShader(
          highlights: pipeline.highlightsValue,
          shadows: pipeline.shadowsValue,
          whites: pipeline.whitesValue,
          blacks: pipeline.blacksValue,
        ).toPass(),
      );
    }

    // Pass 3: vibrance.
    if (pipeline.hasEnabledOp(EditOpType.vibrance)) {
      passes.add(VibranceShader(vibrance: pipeline.vibranceValue).toPass());
    }

    // Pass 4: dehaze (midtone stretch approximation).
    if (pipeline.hasEnabledOp(EditOpType.dehaze)) {
      passes.add(DehazeShader(amount: pipeline.dehazeValue).toPass());
    }

    // Pass 5: levels + gamma.
    final hasLevels = pipeline.hasEnabledOp(EditOpType.levels);
    final hasGamma = pipeline.hasEnabledOp(EditOpType.gamma);
    if (hasLevels || hasGamma) {
      passes.add(
        LevelsGammaShader(
          black: pipeline.levelsBlack,
          white: pipeline.levelsWhite,
          gamma: pipeline.levelsGamma,
        ).toPass(),
      );
    }

    // Pass 6: HSL 8-band.
    if (pipeline.hasEnabledOp(EditOpType.hsl)) {
      passes.add(
        HslShader(
          hueDelta: pipeline.hslHueDelta,
          satDelta: pipeline.hslSatDelta,
          lumDelta: pipeline.hslLumDelta,
        ).toPass(),
      );
    }

    // Pass 7: split toning.
    if (pipeline.hasEnabledOp(EditOpType.splitToning)) {
      passes.add(
        SplitToningShader(
          highlightColor: pipeline.splitHighlightColor,
          shadowColor: pipeline.splitShadowColor,
          balance: pipeline.splitBalance,
        ).toPass(),
      );
    }

    // ---------- Phase 5: effects + detail + blurs ----------

    // Bilateral denoise (detail).
    if (pipeline.hasEnabledOp(EditOpType.denoiseBilateral)) {
      passes.add(
        BilateralDenoiseShader(
          sigmaSpatial:
              pipeline.readParam(EditOpType.denoiseBilateral, 'sigmaSpatial', 2),
          sigmaRange:
              pipeline.readParam(EditOpType.denoiseBilateral, 'sigmaRange', 0.15),
          radius:
              pipeline.readParam(EditOpType.denoiseBilateral, 'radius', 2),
        ).toPass(),
      );
    }

    // Unsharp mask sharpen.
    if (pipeline.hasEnabledOp(EditOpType.sharpen)) {
      passes.add(
        SharpenUnsharpShader(
          amount: pipeline.readParam(EditOpType.sharpen, 'amount'),
          radius: pipeline.readParam(EditOpType.sharpen, 'radius', 1),
        ).toPass(),
      );
    }

    // Tilt-shift.
    if (pipeline.hasEnabledOp(EditOpType.tiltShift)) {
      passes.add(
        TiltShiftShader(
          focusX: pipeline.readParam(EditOpType.tiltShift, 'focusX', 0.5),
          focusY: pipeline.readParam(EditOpType.tiltShift, 'focusY', 0.5),
          focusWidth:
              pipeline.readParam(EditOpType.tiltShift, 'focusWidth', 0.15),
          blurAmount:
              pipeline.readParam(EditOpType.tiltShift, 'blurAmount'),
          angle: pipeline.readParam(EditOpType.tiltShift, 'angle'),
        ).toPass(),
      );
    }

    // Motion blur.
    if (pipeline.hasEnabledOp(EditOpType.motionBlur)) {
      final angle = pipeline.readParam(EditOpType.motionBlur, 'angle');
      passes.add(
        MotionBlurShader(
          directionX: math.cos(angle),
          directionY: math.sin(angle),
          samples: 16,
          strength:
              pipeline.readParam(EditOpType.motionBlur, 'strength'),
        ).toPass(),
      );
    }

    // Vignette.
    if (pipeline.hasEnabledOp(EditOpType.vignette)) {
      passes.add(
        VignetteShader(
          amount: pipeline.readParam(EditOpType.vignette, 'amount'),
          feather: pipeline.readParam(EditOpType.vignette, 'feather', 0.4),
          roundness:
              pipeline.readParam(EditOpType.vignette, 'roundness', 0.5),
          centerX: pipeline.readParam(EditOpType.vignette, 'centerX', 0.5),
          centerY: pipeline.readParam(EditOpType.vignette, 'centerY', 0.5),
        ).toPass(),
      );
    }

    // Chromatic aberration.
    if (pipeline.hasEnabledOp(EditOpType.chromaticAberration)) {
      passes.add(
        ChromaticAberrationShader(
          amount:
              pipeline.readParam(EditOpType.chromaticAberration, 'amount'),
        ).toPass(),
      );
    }

    // Pixelate.
    if (pipeline.hasEnabledOp(EditOpType.pixelate)) {
      final px = pipeline.readParam(EditOpType.pixelate, 'pixelSize', 1);
      if (px > 1.5) {
        passes.add(PixelateShader(pixelSize: px).toPass());
      }
    }

    // Halftone.
    if (pipeline.hasEnabledOp(EditOpType.halftone)) {
      passes.add(
        HalftoneShader(
          dotSize: pipeline.readParam(EditOpType.halftone, 'dotSize', 6),
          angle: pipeline.readParam(EditOpType.halftone, 'angle', 0.785),
        ).toPass(),
      );
    }

    // Glitch.
    if (pipeline.hasEnabledOp(EditOpType.glitch)) {
      passes.add(
        GlitchShader(
          amount: pipeline.readParam(EditOpType.glitch, 'amount'),
          time: DateTime.now().millisecondsSinceEpoch / 1000.0 % 100,
        ).toPass(),
      );
    }

    // Grain.
    if (pipeline.hasEnabledOp(EditOpType.grain)) {
      passes.add(
        GrainShader(
          amount: pipeline.readParam(EditOpType.grain, 'amount'),
          cellSize: pipeline.readParam(EditOpType.grain, 'cellSize', 2),
          seed: 1,
        ).toPass(),
      );
    }

    // NOTE: tone curves (requires async LUT bake) and clarity (needs a
    // blurred sampler) ship in Phase 6.

    return passes;
  }

  // ----- History sync --------------------------------------------------------

  void _onHistoryStateChanged(HistoryState state) {
    if (_disposed) return;
    // Reset the working buffer so workingPipeline == committedPipeline.
    _workingPipeline = EditPipeline.forOriginal('');
    // Rebuild the op-id cache from the committed pipeline so subsequent
    // edits reuse the same ids. Layer ops are skipped because there can
    // be multiple layers of the same kind and a type→id map would only
    // remember the last one. Layer mutations always look up by the
    // layer's own id via [EditPipeline.findById].
    _opIds.clear();
    for (final op in state.pipeline.operations) {
      if (op.type == EditOpType.text ||
          op.type == EditOpType.sticker ||
          op.type == EditOpType.drawing ||
          op.type == EditOpType.adjustmentLayer) {
        continue;
      }
      _opIds[op.type] = op.id;
    }
    // NOTE: cutout images are intentionally NOT garbage-collected here.
    // History changes (including undo past a BG-removal op) must not
    // evict cached cutouts, otherwise a redo would find the layer back
    // in the pipeline with no bitmap to draw. Cutouts are freed in
    // [dispose] or replaced in-place via [_cacheCutoutImage].
    _log.d('history state changed', {
      'ops': state.pipeline.operations.length,
      'canUndo': state.canUndo,
      'canRedo': state.canRedo,
      'cursor': state.cursor,
    });
    rebuildPreview();
  }

  void _commitPipeline(EditPipeline next) {
    if (_disposed) return;
    // Classify the delta between [committedPipeline] and [next] for
    // the last-touched op type:
    //   - op exists in next + not in committed → AppendEdit
    //   - op exists in next + already in committed → ExecuteEdit
    //   - op exists in committed + not in next → ApplyPresetEvent
    //     with the full next pipeline (a clean atomic removal that
    //     works for scalar AND multi-param ops)
    //   - neither → nothing to commit
    final touched = _lastTouchedType;
    if (touched == null) {
      _log.d('commit skipped — no touched op');
      return;
    }
    final inNext = next.findOp(touched);
    final inCommitted = committedPipeline.findOp(touched);

    if (inNext != null) {
      final alreadyInHistory =
          committedPipeline.operations.any((o) => o.id == inNext.id);
      _log.i('commit', {
        'type': touched,
        'action': alreadyInHistory ? 'execute' : 'append',
        'params': inNext.parameters,
      });
      if (alreadyInHistory) {
        historyBloc.add(
          ExecuteEdit(op: inNext, afterParameters: inNext.parameters),
        );
      } else {
        historyBloc.add(AppendEdit(inNext));
      }
    } else if (inCommitted != null) {
      // The op was removed by identity filtering. Commit the whole new
      // pipeline atomically so undo/redo restores the old params
      // correctly for both scalar and multi-param ops (vignette,
      // denoise, etc.) without leaving stale parameters in the pipeline.
      _log.i('commit (remove)',
          {'type': touched, 'prevId': inCommitted.id});
      historyBloc.add(
        ApplyPresetEvent(
          pipeline: next,
          presetName: 'Remove ${touched.split('.').last}',
        ),
      );
    }
    _workingPipeline = EditPipeline.forOriginal('');
    _lastTouchedType = null;
  }

  EditPipeline _upsertOp(
    EditPipeline base,
    String type, {
    required Map<String, dynamic> parameters,
    String? id,
  }) {
    if (id != null) {
      for (final op in base.operations) {
        if (op.id == id) {
          return base.replace(op.copyWith(parameters: parameters));
        }
      }
    } else {
      for (final op in base.operations) {
        if (op.type == type) {
          return base.replace(op.copyWith(parameters: parameters));
        }
      }
    }
    return base.append(
      EditOperation.create(type: type, parameters: parameters),
    );
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _log.i('dispose', {'path': sourcePath});
    await _historySub?.cancel();
    _historySub = null;
    await historyBloc.close();
    await mementoStore.clear();
    // Free every cached cutout image before the preview controller
    // disposes — avoids a tiny GPU-memory leak on session switch.
    for (final img in _cutoutImages.values) {
      img.dispose();
    }
    _cutoutImages.clear();
    previewController.dispose();
    proxy.dispose();
    _log.d('dispose complete');
  }
}
