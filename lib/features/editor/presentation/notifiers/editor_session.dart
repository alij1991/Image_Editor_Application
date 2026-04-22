import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';

import '../../../../core/logging/app_logger.dart';
import '../../../../engine/history/history_bloc.dart';
import '../../../../engine/history/history_event.dart';
import '../../../../engine/history/history_manager.dart';
import '../../../../engine/history/history_state.dart';

import '../../../../ai/services/bg_removal/bg_removal_strategy.dart';
import '../../../../ai/services/face_detect/face_detection_cache.dart';
import '../../../../ai/services/face_detect/face_detection_service.dart';
import '../../../../ai/services/inpaint/inpaint_service.dart';
import '../../../../ai/services/portrait_beauty/eye_brighten_service.dart';
import '../../../../ai/services/style_transfer/style_transfer_service.dart';
import '../../../../ai/services/super_res/super_res_service.dart';
import '../../../../ai/services/portrait_beauty/face_reshape_service.dart';
import '../../../../ai/services/portrait_beauty/portrait_smooth_service.dart';
import '../../../../ai/services/portrait_beauty/teeth_whiten_service.dart';
import '../../../../ai/services/sky_replace/sky_preset.dart';
import '../../../../ai/services/sky_replace/sky_replace_service.dart';
import '../../../../engine/history/memento_store.dart';
import '../../../../engine/layers/content_layer.dart';
import '../../../../engine/layers/cutout_store.dart';
import '../../../../engine/pipeline/edit_op_type.dart';
import '../../../../engine/pipeline/geometry_state.dart';
import '../../../../engine/pipeline/edit_operation.dart';
import '../../../../engine/pipeline/edit_pipeline.dart';
import '../../../../engine/pipeline/op_spec.dart';
import '../../../../engine/pipeline/pipeline_extensions.dart';
import '../../../../engine/pipeline/tone_curve_set.dart';
import '../../../../engine/pipeline/preview_proxy.dart';
import '../../../../engine/presets/preset.dart';
import '../../../../engine/presets/preset_applier.dart';
import '../../../../engine/presets/preset_metadata.dart';
import '../../data/project_store.dart';
import '../../../../engine/rendering/shader_texture_pool.dart';
import 'ai_coordinator.dart';
import 'auto_save_controller.dart';
import 'render_driver.dart';
import '../../domain/auto_enhance/auto_enhance_analyzer.dart';
import '../../domain/auto_enhance/auto_section_analyzer.dart';
import '../../domain/auto_enhance/auto_white_balance.dart';
import '../../domain/auto_enhance/histogram_analyzer.dart';
import '../../domain/preset_thumbnail_cache.dart';
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
    required this.projectStore,
    required this.cutoutStore,
  });

  static Future<EditorSession> start({
    required String sourcePath,
    required PreviewProxy proxy,
    ProjectStore? projectStore,
    CutoutStore? cutoutStore,
    MementoStore? mementoStore,
  }) async {
    _log.i('start', {'path': sourcePath});
    // Phase V.2: the caller (editor_notifier) constructs the
    // MementoStore with `ramRingCapacity: budget.maxRamMementos` so
    // undo/redo uses the full RAM tier on the device. Tests + legacy
    // callers omit it and fall back to the MementoStore default
    // (`ramRingCapacity: 3`, matching the pre-V.2 hardcode).
    final memStore = mementoStore ?? MementoStore();
    await memStore.init();
    _log.d('memento store init complete');

    // Try to rehydrate the parametric pipeline from disk so the user
    // returns to the same edit they left. Falls back to an empty
    // pipeline silently — load() returns null on first open or after
    // a schema bump, and we never want auto-restore to block the
    // session from starting.
    final store = projectStore ?? ProjectStore();
    final restored = await store.load(sourcePath);
    final initial = restored ?? EditPipeline.forOriginal(sourcePath);
    if (restored != null) {
      _log.i('restored', {'ops': restored.operations.length});
    }

    final history = HistoryManager.withPipeline(
      mementoStore: memStore,
      initial: initial,
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
      mementoStore: memStore,
      projectStore: store,
      cutoutStore: cutoutStore ?? CutoutStore(),
    );
    session._historySub = bloc.stream.listen(session._onHistoryStateChanged);
    // Hydrate any cutouts the restored pipeline references. Fire-and-
    // forget — the UI renders layers-without-cutouts immediately and
    // flips to the real bitmaps once PNG decodes land (typically <1 s
    // for a 12 MP image). If the user starts editing before the
    // hydrate completes, their new edits sit on top of the soon-to-
    // arrive cutouts, so nothing races destructively.
    unawaited(session._aiCoordinator.hydrate(history.currentPipeline));
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
  final ProjectStore projectStore;
  final MementoStore mementoStore;
  final CutoutStore cutoutStore;

  /// Phase VI.1: ping-pong pool for intermediate shader-pass textures.
  /// Lives for the session lifetime so Skia's GPU texture cache retains
  /// the two slot-sized textures across frames. Disposed in [dispose].
  /// Consumed by the editor canvas' [ShaderRenderer]; other renderer
  /// callers (export, before-after compare) are transient and pass null.
  final ShaderTexturePool texturePool = ShaderTexturePool();

  /// Phase VII.3: render-path state owner. `_passesFor` moved inside
  /// (as `renderDriver.passesFor(pipeline)`), along with the tone-curve
  /// LUT cache, the bake coalescing queue, the matrix-scratch buffer,
  /// and the `CurveLutBaker` wiring. Session delegates rebuildPreview
  /// through it so the canvas keeps one source of truth for the
  /// `List<ShaderPass>` it draws.
  late final RenderDriver renderDriver = RenderDriver(
    onRebuildPreview: rebuildPreview,
    isSessionDisposed: () => _disposed,
  );

  /// Working pipeline during an uncommitted drag. Reset after each commit
  /// and whenever history changes externally (undo/redo).
  EditPipeline _workingPipeline = EditPipeline.forOriginal('');

  /// Pipeline emitted by the history bloc that intentionally differs from
  /// the persisted [HistoryManager.currentPipeline] — e.g. the tap-hold
  /// before/after compare which dispatches `SetAllOpsEnabled` without
  /// writing a history entry. When set, [workingPipeline] returns this
  /// view instead of the committed one so the renderer reflects the
  /// transient state. Cleared the next time the bloc emits a state whose
  /// pipeline matches the manager's.
  EditPipeline? _transientPipeline;

  /// Per-op-type id cache. When the user drags the same slider repeatedly
  /// we reuse the op id so the history stays a single entry per commit.
  final Map<String, String> _opIds = {};

  /// The op-type of the most-recently modified op. Used by
  /// [_commitPipeline] so a commit pushes the correct op through the bloc.
  String? _lastTouchedType;

  /// Phase VII.2/VII.4: AI apply surface + cutout cache + dispose-
  /// guarded inference wrapper. Owns the cutout bitmap map + hydrate/
  /// persist lifecycle (VII.2) and the 9 `applyXxx` methods (VII.4).
  /// The session exposes thin public delegates so callers don't need
  /// to know the coordinator exists; internally the coordinator owns
  /// all AI coordination. Two callbacks bridge back to session state:
  /// `commitAdjustmentLayer` wraps the history-bloc commit and
  /// `detectFaces` routes through the session face-detection cache.
  late final AiCoordinator _aiCoordinator = AiCoordinator(
    sourcePath: sourcePath,
    cutoutStore: cutoutStore,
    onHydrateLanded: rebuildPreview,
    commitAdjustmentLayer: _commitAdjustmentLayer,
    detectFaces: (detector) =>
        _faceDetectionCache.getOrDetect(
          sourcePath: sourcePath,
          detect: () => detector.detectFromPath(sourcePath),
        ),
  );

  /// Phase V.6 test-observable counter, preserved for existing
  /// callers — delegates through [renderDriver] which actually owns
  /// the bake state post-VII.3.
  @visibleForTesting
  int get debugCurveBakeIsolateLaunches =>
      // ignore: invalid_use_of_visible_for_testing_member
      renderDriver.debugCurveBakeIsolateLaunches;

  /// Phase V.1: session-scoped cache of face-detection results. All
  /// four beauty services (Portrait Smooth, Eye Brighten, Teeth
  /// Whiten, Face Reshape) detect the same faces on the same source
  /// image; the first `applyXxx` call pays the ML Kit cost
  /// (~700 ms on mid-range Android), subsequent calls hit the cache.
  /// Applying all three basic beauty ops drops from 3× detection
  /// to 1× — the single biggest user-visible perf win per the
  /// `docs/IMPROVEMENTS.md` register.
  ///
  /// Keyed by source path — the cache structure admits a future
  /// session that swaps source images in place (scrollable project
  /// view) without a code change. Cleared implicitly when the
  /// session is disposed.
  final FaceDetectionCache _faceDetectionCache = FaceDetectionCache();

  StreamSubscription<HistoryState>? _historySub;
  bool _disposed = false;

  ui.Image get sourceImage {
    final img = proxy.image;
    if (img == null) {
      throw StateError('EditorSession used before proxy was loaded');
    }
    return img;
  }

  EditPipeline get workingPipeline {
    if (_transientPipeline != null) return _transientPipeline!;
    return _workingPipeline.operations.isEmpty
        ? historyManager.currentPipeline
        : _workingPipeline;
  }

  EditPipeline get committedPipeline => historyManager.currentPipeline;

  // ----- Layer selection / interactive transforms -------------------------
  //
  // Phase 10-drag: stickers, text, and (in future) drawings can be tapped
  // to select and then dragged, pinched, or rotated directly on the
  // canvas. The overlay lives inside [SnapseedGestureLayer]; this
  // section is purely the state + mutation entry point.

  /// Id of the currently-selected layer, or null for none. Watched by
  /// the canvas overlay so selection handles can animate in/out.
  final ValueNotifier<String?> selectedLayerId = ValueNotifier<String?>(null);

  /// Select a layer by id, or clear the selection with null.
  void selectLayer(String? id) {
    if (_disposed) return;
    if (selectedLayerId.value == id) return;
    _log.i('selectLayer', {'id': id});
    selectedLayerId.value = id;
  }

  /// Apply a gesture delta to the selected layer. [dxNorm] / [dyNorm]
  /// are normalised 0..1 canvas coords; [scaleFactor] is multiplicative
  /// (1.0 = no change); [dRotation] is radians. Changes go through the
  /// preview path so the drag is smooth; a commit lands on gesture end.
  void updateSelectedLayerTransform({
    double dxNorm = 0,
    double dyNorm = 0,
    double scaleFactor = 1.0,
    double dRotation = 0,
  }) {
    if (_disposed) return;
    final id = selectedLayerId.value;
    if (id == null) return;
    final current = committedPipeline.contentLayers
        .firstWhere((l) => l.id == id, orElse: () => _nullLayer);
    if (identical(current, _nullLayer)) return;

    ContentLayer updated;
    if (current is TextLayer) {
      updated = current.copyWith(
        x: (current.x + dxNorm).clamp(0.0, 1.0),
        y: (current.y + dyNorm).clamp(0.0, 1.0),
        scale: (current.scale * scaleFactor).clamp(0.1, 10.0),
        rotation: current.rotation + dRotation,
      );
    } else if (current is StickerLayer) {
      updated = current.copyWith(
        x: (current.x + dxNorm).clamp(0.0, 1.0),
        y: (current.y + dyNorm).clamp(0.0, 1.0),
        scale: (current.scale * scaleFactor).clamp(0.1, 10.0),
        rotation: current.rotation + dRotation,
      );
    } else {
      // Drawings / adjustment layers have no draggable transform in
      // this phase. Silently ignore.
      return;
    }

    final opType = opTypeForLayerKind(updated.kind);
    final next = _upsertOp(
      committedPipeline,
      opType,
      id: updated.id,
      parameters: updated.toParams(),
    );
    _workingPipeline = next;
    rebuildPreview();
    previewController.scheduleCommit(next);
  }

  /// Flush the pending layer-transform commit on gesture end so the
  /// drag lands as a single history entry.
  void flushLayerTransform() {
    if (_disposed) return;
    previewController.flushCommit();
  }

  /// Sentinel returned by [updateSelectedLayerTransform]'s lookup when
  /// the selected id doesn't match any current layer (e.g. just deleted).
  /// Identity-compared against the firstWhere result to branch early.
  static final ContentLayer _nullLayer = StickerLayer(
    id: '__none__',
    character: '',
    fontSize: 0,
  );

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
    // Any direct slider edit invalidates the "applied preset" record —
    // the pipeline is no longer a pure preset state and it would be
    // misleading for the strip to keep highlighting the tile. Presets
    // re-applied via `applyPreset` / `setPresetAmount` set the record
    // back after this call.
    if (appliedPreset.value != null) {
      appliedPreset.value = null;
    }
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

  /// Set (or clear) the crop aspect-ratio constraint. Used by the
  /// aspect chips (1:1, 4:5, 16:9, …) to lock subsequent drag-handle
  /// resizes. Preserves any committed crop rect alongside the aspect.
  void setCropAspectRatio(double? ratio) {
    if (_disposed) return;
    _log.i('setCropAspectRatio', {'ratio': ratio});
    final existing = committedPipeline.findOp(EditOpType.crop);
    final params = <String, dynamic>{
      ...?existing?.parameters,
      'aspectRatio': ratio,
    };
    if (ratio == null) params.remove('aspectRatio');
    _applyEdit(
      type: EditOpType.crop,
      params: params,
      // Only drop the op when nothing is left — aspect cleared AND no
      // committed rect — otherwise the rect would vanish too.
      removeIfPresent: params.isEmpty ||
          (params.length == 1 && params.containsKey('aspectRatio') &&
              params['aspectRatio'] == null),
    );
    previewController.flushCommit();
  }

  /// Set (or clear) the master tone-curve control points — kept for
  /// backwards compatibility with the master-only sheet. Internally
  /// merges into the existing per-channel set.
  void setToneCurve(List<List<double>>? points) =>
      setToneCurveChannel(ToneCurveChannel.master, points);

  /// Set (or clear) one channel's tone-curve control points. [points]
  /// is a list of [x, y] pairs in [0..1]^2. Passing null (or an
  /// identity-shaped list) drops that channel; if every channel is
  /// then identity the entire toneCurve op is removed so the shader
  /// pass disappears. Each channel is sorted by x before commit so
  /// the pipeline reader can rely on monotonic input.
  void setToneCurveChannel(
    ToneCurveChannel channel,
    List<List<double>>? points,
  ) {
    if (_disposed) return;
    _log.i('setToneCurve', {
      'channel': channel.name,
      'count': points?.length,
    });
    final sorted = (points == null || points.length < 2)
        ? null
        : ([...points]..sort((a, b) => a[0].compareTo(b[0])));
    final existing = committedPipeline.toneCurves ?? const ToneCurveSet();
    final next = existing.withChannel(
      channel,
      sorted == null
          ? null
          : [for (final p in sorted) [p[0], p[1]]],
    );
    if (next.isAllIdentity) {
      _applyEdit(
        type: EditOpType.toneCurve,
        params: const {},
        removeIfPresent: true,
      );
      previewController.flushCommit();
      return;
    }
    _applyEdit(
      type: EditOpType.toneCurve,
      params: {
        if (next.master != null) 'points': next.master,
        if (next.red != null) 'red': next.red,
        if (next.green != null) 'green': next.green,
        if (next.blue != null) 'blue': next.blue,
      },
      removeIfPresent: false,
    );
    previewController.flushCommit();
  }

  /// Move the vignette center to normalized [0..1] image coords.
  /// No-op if the vignette op isn't yet present — the on-canvas
  /// drag handle only renders when the user has authored an amount,
  /// so the parameter is always merged into an existing op.
  void setVignetteCenter(double cx, double cy) {
    if (_disposed) return;
    final existing = committedPipeline.findOp(EditOpType.vignette);
    if (existing == null) return;
    final params = <String, dynamic>{
      ...existing.parameters,
      'centerX': cx.clamp(0.0, 1.0),
      'centerY': cy.clamp(0.0, 1.0),
    };
    _applyEdit(
      type: EditOpType.vignette,
      params: params,
      removeIfPresent: false,
    );
  }

  /// Apply (or clear) the concrete crop rectangle. [rect] is in
  /// normalized [0..1] source-image coordinates. Pass null to drop
  /// the rect (the aspect-ratio chip stays selected if set).
  void setCropRect(CropRect? rect) {
    if (_disposed) return;
    _log.i('setCropRect', {'rect': rect.toString()});
    final existing = committedPipeline.findOp(EditOpType.crop);
    final params = <String, dynamic>{
      ...?existing?.parameters,
      if (rect != null) ...rect.toParams(),
    };
    if (rect == null) {
      params.remove('left');
      params.remove('top');
      params.remove('right');
      params.remove('bottom');
    }
    _applyEdit(
      type: EditOpType.crop,
      params: params,
      // Only drop the op when nothing is left.
      removeIfPresent: params.isEmpty,
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
      ApplyPipelineEvent(pipeline: next, presetName: 'Add ${layer.kind.name}'),
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
      ApplyPipelineEvent(pipeline: next, presetName: 'Delete layer'),
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
      ApplyPipelineEvent(pipeline: next, presetName: 'Reorder layer'),
    );
  }

  // ----- AI features --------------------------------------------------------
  //
  // Phase VII.4: every `applyXxx` method migrated into
  // [AiCoordinator]; the session now exposes thin delegates so the
  // public surface callers (editor_page handlers) don't need to know
  // the coordinator exists. The coordinator owns the service
  // dispatch + cutout cache + inference dispose-guard + commit-to-
  // history flow. Two session-provided callbacks bridge back:
  // `_commitAdjustmentLayer` (pipeline append + history bloc) and
  // `detectFacesCached` (face-detection cache routing).

  /// Append [layer] onto the committed pipeline and push it through
  /// the history bloc with [presetName] as the history-timeline
  /// label. Exposed as a callback to [AiCoordinator] so the
  /// coordinator's `applyXxx` methods don't import the history
  /// plumbing directly.
  void _commitAdjustmentLayer({
    required AdjustmentLayer layer,
    required String presetName,
  }) {
    final op = EditOperation.create(
      type: EditOpType.adjustmentLayer,
      parameters: layer.toParams(),
    ).copyWith(id: layer.id);
    historyBloc.add(
      ApplyPipelineEvent(
        pipeline: committedPipeline.append(op),
        presetName: presetName,
      ),
    );
  }

  Future<String> applyBackgroundRemoval({
    required BgRemovalStrategy strategy,
    required String newLayerId,
  }) =>
      _aiCoordinator.applyBackgroundRemoval(
        strategy: strategy,
        newLayerId: newLayerId,
      );

  /// Phase V.1 session-level face-detection cache entry point. Kept
  /// on the session because non-AI callers may read it in the future;
  /// [AiCoordinator.detectFaces] routes here through its callback.
  Future<List<DetectedFace>> detectFacesCached({
    required FaceDetectionService detector,
  }) {
    return _faceDetectionCache.getOrDetect(
      sourcePath: sourcePath,
      detect: () => detector.detectFromPath(sourcePath),
    );
  }

  /// Number of times the underlying face detector was actually
  /// invoked by this session. Pinned by
  /// `editor_session_face_cache_test` (three sequential beauty ops
  /// → 1 detect call).
  @visibleForTesting
  int get debugFaceDetectionCallCount =>
      _faceDetectionCache.debugDetectCallCount;

  Future<String> applyPortraitSmooth({
    required PortraitSmoothService service,
    required String newLayerId,
  }) =>
      _aiCoordinator.applyPortraitSmooth(
        service: service,
        newLayerId: newLayerId,
      );

  Future<String> applyEyeBrighten({
    required EyeBrightenService service,
    required String newLayerId,
  }) =>
      _aiCoordinator.applyEyeBrighten(
        service: service,
        newLayerId: newLayerId,
      );

  Future<String> applyTeethWhiten({
    required TeethWhitenService service,
    required String newLayerId,
  }) =>
      _aiCoordinator.applyTeethWhiten(
        service: service,
        newLayerId: newLayerId,
      );

  Future<String> applyFaceReshape({
    required FaceReshapeService service,
    required String newLayerId,
    required Map<String, double> reshapeParams,
  }) =>
      _aiCoordinator.applyFaceReshape(
        service: service,
        newLayerId: newLayerId,
        reshapeParams: reshapeParams,
      );

  Future<String> applySkyReplace({
    required SkyReplaceService service,
    required String newLayerId,
    required SkyPreset preset,
  }) =>
      _aiCoordinator.applySkyReplace(
        service: service,
        newLayerId: newLayerId,
        preset: preset,
      );

  Future<String> applyEnhance({
    required SuperResService service,
    required String newLayerId,
  }) =>
      _aiCoordinator.applyEnhance(
        service: service,
        newLayerId: newLayerId,
      );

  Future<String> applyStyleTransfer({
    required StyleTransferService service,
    required Float32List styleVector,
    required String styleName,
    required String newLayerId,
  }) =>
      _aiCoordinator.applyStyleTransfer(
        service: service,
        styleVector: styleVector,
        styleName: styleName,
        newLayerId: newLayerId,
      );

  Future<String> applyInpainting({
    required InpaintService service,
    required Uint8List maskRgba,
    required int maskWidth,
    required int maskHeight,
    required String newLayerId,
  }) =>
      _aiCoordinator.applyInpainting(
        service: service,
        maskRgba: maskRgba,
        maskWidth: maskWidth,
        maskHeight: maskHeight,
        newLayerId: newLayerId,
      );

  // ----- Existing mutators --------------------------------------------------

  /// Drop every adjustment and go back to the original image. Recorded
  /// as a single history entry (via the preset apply path) so undo
  /// restores all the prior edits at once.
  void resetAll() {
    if (_disposed) return;
    _log.i('resetAll');
    historyBloc.add(
      ApplyPipelineEvent(
        pipeline: EditPipeline.forOriginal(sourcePath),
        presetName: 'Reset',
      ),
    );
  }

  /// Run an automatic adjustment pass over the current image and fold
  /// the computed values into the pipeline as a single atomic commit.
  /// See [AutoFixScope] for the available scopes.
  ///
  /// Returns `true` if at least one op was applied, `false` if the
  /// analyser had nothing useful to change (already well-exposed etc.)
  /// or the source image isn't ready.
  Future<bool> applyAuto(AutoFixScope scope) async {
    if (_disposed) return false;
    _log.i('applyAuto', {'scope': scope.name});
    final ui.Image source;
    try {
      source = sourceImage;
    } catch (_) {
      _log.w('applyAuto: source not ready');
      return false;
    }
    final preset = await const _AutoFix().analyze(source, scope);
    if (preset == null || preset.operations.isEmpty) {
      _log.i('applyAuto: nothing to change');
      return false;
    }
    applyPreset(preset);
    return true;
  }

  /// Downscaled (128 px long-edge) copy of the source image used to
  /// render the preset-strip thumbnails. Computed once on session
  /// start — the strip subscribes and rebuilds tiles when it flips
  /// from null → loaded. Disposed in [dispose].
  final ValueNotifier<ui.Image?> thumbnailProxy = ValueNotifier<ui.Image?>(null);

  /// Phase VI.6: process-wide [PresetThumbnailCache] singleton.
  /// Entries are keyed by `(previewHash, preset.id)` so re-opening
  /// the same photo reuses recipes across sessions.
  PresetThumbnailCache get presetThumbnailCache =>
      PresetThumbnailCache.instance;

  /// Content hash of [thumbnailProxy]'s bytes. Set once in
  /// [ensureThumbnailProxy] after the proxy decode lands; fed into
  /// `PresetThumbnailCache.recipeFor` by every preset tile. Null
  /// during the brief window between session start and proxy load.
  String? _previewHash;

  /// Exposed for the preset strip (reads on every tile build).
  String? get previewHash => _previewHash;

  /// Compute the 128 px thumbnail proxy once the source image is
  /// ready. Called from [EditorNotifier] after the proxy finishes
  /// decoding. Safe to call multiple times — subsequent calls are
  /// no-ops once [thumbnailProxy] has a value.
  Future<void> ensureThumbnailProxy() async {
    if (_disposed) return;
    if (thumbnailProxy.value != null) return;
    final src = proxy.image;
    if (src == null) return;
    try {
      final proxyImg = await buildThumbnailProxy(src);
      if (_disposed) {
        proxyImg.dispose();
        return;
      }
      // Phase VI.6: hash the proxy bytes so the module-level
      // thumbnail cache can tag recipes by photo. Done in parallel
      // with setting the ValueNotifier — worst case the strip shows
      // the proxy a frame before the cache key is ready, and falls
      // through to a miss-then-build on that frame.
      _previewHash = await hashPreviewImage(proxyImg);
      if (_disposed) {
        proxyImg.dispose();
        return;
      }
      thumbnailProxy.value = proxyImg;
      _log.d('thumbnail proxy ready', {
        'w': proxyImg.width,
        'h': proxyImg.height,
        'hash': _previewHash?.substring(0, 8) ?? 'null',
      });
    } catch (e, st) {
      _log.w('thumbnail proxy build failed', {'error': '$e', 'stack': '$st'});
    }
  }

  /// The preset most-recently applied to this session (if any), along
  /// with its current intensity in the 0.0–1.5 range. Exposed so the
  /// preset strip can show the Amount slider for the active preset and
  /// paint its tile as "selected".
  ///
  /// Reset to null on undo/redo that crosses the application boundary
  /// (handled in [_onHistoryStateChanged] — we can't linearly
  /// re-interpolate past an undo so the next drag starts fresh).
  final ValueNotifier<AppliedPresetRecord?> appliedPreset =
      ValueNotifier<AppliedPresetRecord?>(null);

  /// Stamp a [Preset] into the pipeline. Every op in the preset replaces
  /// any same-typed op in the pipeline (matching Lightroom's behavior).
  /// The result is committed as a single atomic history entry so undo
  /// reverts the whole preset in one step.
  ///
  /// [amount] is optional; when omitted we pick a sensible default
  /// based on the preset's strength classification (1.0 for
  /// subtle/standard presets, 0.8 for strong presets so users have
  /// headroom below and above without reaching for the slider).
  void applyPreset(Preset preset, {double? amount}) {
    if (_disposed) return;
    final effectiveAmount = amount ?? PresetMetadata.defaultAmountOf(preset);
    _log.i('applyPreset', {
      'name': preset.name,
      'ops': preset.operations.length,
      'amount': effectiveAmount.toStringAsFixed(2),
    });
    const applier = PresetApplier();
    final next =
        applier.apply(preset, committedPipeline, amount: effectiveAmount);
    // Fire the atomic preset event. The bloc handler commits the whole
    // pipeline as one history entry and emits a new state; our stream
    // subscription will pick it up and call rebuildPreview automatically.
    historyBloc.add(
      ApplyPipelineEvent(pipeline: next, presetName: preset.name),
    );
    // Remember the applied preset so the Amount slider can tweak it
    // without a second tap on the tile.
    appliedPreset.value = AppliedPresetRecord(
      preset: preset,
      amount: effectiveAmount,
    );
  }

  /// Re-apply the currently-active preset at a new intensity.
  ///
  /// Called from the Amount slider in the preset strip. Produces a
  /// single history entry per commit — the caller should call this on
  /// slider drag (scheduleCommit) and flush on release.
  void setPresetAmount(double amount) {
    if (_disposed) return;
    final record = appliedPreset.value;
    if (record == null) {
      _log.w('setPresetAmount: no preset active, ignoring');
      return;
    }
    final clamped = amount.clamp(0.0, 1.5);
    _log.d('setPresetAmount', {
      'preset': record.preset.name,
      'amount': clamped.toStringAsFixed(2),
    });
    const applier = PresetApplier();
    final next =
        applier.apply(record.preset, committedPipeline, amount: clamped);
    historyBloc.add(
      ApplyPipelineEvent(
        pipeline: next,
        presetName: '${record.preset.name} (${(clamped * 100).round()}%)',
      ),
    );
    appliedPreset.value = record.copyWith(amount: clamped);
  }

  // ----- Render path ---------------------------------------------------------

  /// Apply the current pipeline and push the resulting passes + geometry
  /// + content layers to the preview. Called when the session starts
  /// and after history changes.
  ///
  /// [AdjustmentLayer]s need special handling: the pipeline only stores
  /// metadata (the adjustment kind + layer id), and the volatile
  /// [AdjustmentLayer.cutoutImage] has to be filled in from the
  /// [_aiCoordinator]'s cutout cache before handing the list to the
  /// preview controller.
  void rebuildPreview() {
    if (_disposed) return;
    final pipelineToRender = workingPipeline;
    final passes = renderDriver.passesFor(pipelineToRender);
    final geometry = pipelineToRender.geometryState;
    final rawLayers = pipelineToRender.contentLayers;
    final layers = <ContentLayer>[];
    for (final layer in rawLayers) {
      if (layer is AdjustmentLayer) {
        final img = _aiCoordinator.cutoutImageFor(layer.id);
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
      'cutouts': _aiCoordinator.cutoutCount,
    });
    previewController.setPasses(passes);
    previewController.setGeometry(geometry);
    previewController.setLayers(layers);
  }

  /// Public accessor for the cached cutout of an AdjustmentLayer.
  /// Returns null if the layer has no cached image yet (e.g. session
  /// reloaded from a persisted pipeline). The Refine flow reads this
  /// to seed its overlay.
  ui.Image? cutoutImageFor(String layerId) =>
      _aiCoordinator.cutoutImageFor(layerId);

  /// Replace the cached cutout for [layerId] with [image] and rebuild
  /// the preview so the canvas picks up the new mask immediately.
  /// Used by the Refine overlay's Done callback — the layer's pipeline
  /// op stays unchanged, only the volatile bitmap swaps. Returns false
  /// when the id no longer matches any AdjustmentLayer (rare race if
  /// the user deleted the layer mid-refine).
  bool replaceCutoutImage(String layerId, ui.Image image) {
    if (_disposed) {
      image.dispose();
      return false;
    }
    final exists = committedPipeline.contentLayers
        .whereType<AdjustmentLayer>()
        .any((l) => l.id == layerId);
    if (!exists) {
      _log.w('replaceCutoutImage: layer not found', {'id': layerId});
      image.dispose();
      return false;
    }
    _log.i('replaceCutoutImage', {
      'id': layerId,
      'w': image.width,
      'h': image.height,
    });
    _aiCoordinator.cacheCutoutImage(layerId, image);
    rebuildPreview();
    return true;
  }

  // ----- History sync --------------------------------------------------------

  void _onHistoryStateChanged(HistoryState state) {
    if (_disposed) return;
    // The bloc may emit a *transient* pipeline that does not match the
    // history manager's committed pipeline (the tap-hold compare is the
    // canonical case — `SetAllOpsEnabled` toggles a view without writing
    // a history entry). Detect that by identity: a normal commit emits
    // `_snapshot()` whose pipeline IS the manager's currentPipeline, so
    // identical() is true; a transient emit produces a fresh object.
    final committed = historyManager.currentPipeline;
    if (!identical(state.pipeline, committed)) {
      _transientPipeline = state.pipeline;
      // Skip the working-buffer reset and id-cache rebuild — they would
      // either drop the user's mid-drag state or repoint ids at the
      // transient ops. Just re-render from the transient view.
      _log.d('history transient view', {
        'ops': state.pipeline.operations.length,
      });
      rebuildPreview();
      return;
    }
    _transientPipeline = null;
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
    // [dispose] (via [_aiCoordinator.dispose]) or replaced in-place
    // via [AiCoordinator.cacheCutoutImage].
    _log.d('history state changed', {
      'ops': state.pipeline.operations.length,
      'canUndo': state.canUndo,
      'canRedo': state.canRedo,
      'cursor': state.cursor,
    });
    rebuildPreview();
    _scheduleAutoSave(state.pipeline);
  }

  // ----- Auto-save -----------------------------------------------------------
  //
  // Every committed history change schedules a save 600 ms in the
  // future through [_autoSaveController]. Phase VII.1 extracted the
  // debounce + dispose-flush into `AutoSaveController` so the session
  // only sees `schedule` / `flushAndDispose`. The debounce semantics,
  // IO-error tolerance, and final-flush-on-dispose are preserved.
  late final AutoSaveController _autoSaveController = AutoSaveController(
    sourcePath: sourcePath,
    projectStore: projectStore,
  );

  void _scheduleAutoSave(EditPipeline pipeline) {
    // Empty pipelines (the user just hit Reset) are still worth
    // persisting — restore should put them back in the cleared state
    // so they don't get a surprise on next open. The controller
    // doesn't filter them out.
    _autoSaveController.schedule(pipeline);
  }

  void _commitPipeline(EditPipeline next) {
    if (_disposed) return;
    // Classify the delta between [committedPipeline] and [next] for
    // the last-touched op type:
    //   - op exists in next + not in committed → AppendEdit
    //   - op exists in next + already in committed → ExecuteEdit
    //   - op exists in committed + not in next → ApplyPipelineEvent
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
        ApplyPipelineEvent(
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
    // Cancel any pending auto-save AND flush one final write so the
    // user's last edit before exit isn't lost to the debounce timer.
    // [historyManager.currentPipeline] is the authoritative committed
    // state — use it instead of whatever pipeline was last scheduled
    // through the debounce so stale intermediates don't overwrite a
    // later commit.
    await _autoSaveController.flushAndDispose(historyManager.currentPipeline);
    await _historySub?.cancel();
    _historySub = null;
    await historyBloc.close();
    await mementoStore.clear();
    // Free every cached cutout image + halt pending persist/hydrate
    // work before the preview controller disposes — avoids a tiny
    // GPU-memory leak on session switch.
    _aiCoordinator.dispose();
    renderDriver.dispose();
    selectedLayerId.dispose();
    appliedPreset.dispose();
    thumbnailProxy.value?.dispose();
    thumbnailProxy.dispose();
    previewController.dispose();
    texturePool.dispose();
    proxy.dispose();
    _log.d('dispose complete');
  }
}

/// Snapshot of a preset application — the preset itself plus the
/// current Amount (0.0–1.5). Published through
/// [EditorSession.appliedPreset] so the strip can highlight the active
/// tile and drive the intensity slider without a second tap.
class AppliedPresetRecord {
  const AppliedPresetRecord({required this.preset, required this.amount});

  final Preset preset;
  final double amount;

  AppliedPresetRecord copyWith({Preset? preset, double? amount}) =>
      AppliedPresetRecord(
        preset: preset ?? this.preset,
        amount: amount ?? this.amount,
      );
}

/// Scope passed to [EditorSession.applyAuto].
enum AutoFixScope {
  /// Full Lightroom-mobile-style auto — exposure + contrast +
  /// highlights + shadows + whites + blacks + vibrance + WB.
  all,

  /// Only Light-section sliders (exposure, contrast, highlights,
  /// shadows, whites, blacks).
  light,

  /// Only Color-section sliders (temperature, tint, vibrance,
  /// saturation).
  color,

  /// Only temperature + tint — classical auto white balance.
  whiteBalance,
}

/// Internal glue that runs the histogram + the right analyser for the
/// requested [AutoFixScope] and returns a [Preset] ready for
/// [EditorSession.applyPreset]. Kept private to keep the public API on
/// EditorSession surface-minimal.
class _AutoFix {
  const _AutoFix();

  Future<Preset?> analyze(ui.Image source, AutoFixScope scope) async {
    const histogram = HistogramAnalyzer();
    // Phase VI.4: run the pixel-binning + percentile math off the main
    // isolate. Engine-bound downscale + `toByteData` still happen on
    // the UI isolate inside `analyzeInIsolate` because they require
    // the raster thread; only the pure-Dart CPU portion crosses the
    // compute() boundary.
    final stats = await histogram.analyzeInIsolate(source);
    if (stats == null) return null;
    switch (scope) {
      case AutoFixScope.all:
        return const AutoEnhanceAnalyzer().analyze(stats);
      case AutoFixScope.light:
        return const AutoSectionAnalyzer().analyzeLight(stats);
      case AutoFixScope.color:
        return const AutoSectionAnalyzer().analyzeColor(stats);
      case AutoFixScope.whiteBalance:
        return const AutoWhiteBalance().asPreset(stats);
    }
  }
}
