import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:image_picker/image_picker.dart';
import 'package:uuid/uuid.dart';

import 'dart:typed_data';

import '../../../../ai/models/model_registry.dart' show ResolvedModel;
import '../../../../ai/runtime/ml_runtime.dart';
import '../../../../ai/services/bg_removal/bg_removal_strategy.dart';
import '../../../../ai/services/face_detect/face_detection_service.dart';
import '../../../../ai/services/inpaint/inpaint_service.dart';
import '../../../../ai/services/portrait_beauty/eye_brighten_service.dart';
import '../../../../ai/services/portrait_beauty/face_reshape_service.dart';
import '../../../../ai/services/portrait_beauty/portrait_smooth_service.dart';
import '../../../../ai/services/portrait_beauty/teeth_whiten_service.dart';
import '../../../../ai/services/sky_replace/sky_preset.dart';
import '../../../../ai/services/sky_replace/sky_replace_service.dart';
import '../../../../ai/services/style_transfer/style_predict_service.dart';
import '../../../../ai/services/style_transfer/style_transfer_service.dart';
import '../../../../core/feedback/user_feedback.dart';
import '../../../../core/logging/app_logger.dart';
import '../../../../core/platform/haptics.dart';
import '../../../../core/preferences/first_run_flag.dart';
import '../../../../core/theme/spacing.dart';
import '../../../../di/providers.dart';
import '../../../../engine/pipeline/edit_op_type.dart';
import '../../../../engine/pipeline/edit_operation.dart';
import '../../../../engine/presets/preset.dart';
import '../../../../engine/history/history_event.dart';
import '../../../../engine/history/history_state.dart';
import '../../../../engine/layers/content_layer.dart';
import '../../../../engine/history/op_display_names.dart';
import '../../../../engine/pipeline/op_spec.dart';
import '../../../../engine/rendering/shader_registry.dart';
import '../../../../engine/pipeline/pipeline_extensions.dart';
import '../../../settings/presentation/widgets/model_manager_sheet.dart';
import '../notifiers/editor_notifier.dart';
import '../notifiers/editor_session.dart';
import '../notifiers/editor_state.dart';
import '../widgets/before_after_split.dart';
import '../widgets/before_after_toggle.dart';
import '../widgets/bg_removal_picker_sheet.dart';
import '../widgets/draw_mode_overlay.dart';
import '../widgets/sky_replace_picker_sheet.dart';
import '../widgets/geometry_panel.dart';
import '../widgets/hsl_panel.dart';
import '../widgets/image_canvas.dart';
import '../widgets/layer_stack_panel.dart';
import '../widgets/lightroom_panel.dart';
import '../widgets/preset_strip.dart';
import '../widgets/export_sheet.dart';
import '../widgets/history_timeline_sheet.dart';
import '../widgets/perf_hud.dart';
import '../../../settings/presentation/pages/settings_page.dart';
import '../widgets/snapseed_gesture_layer.dart';
import '../widgets/vignette_center_overlay.dart';
import '../widgets/split_toning_panel.dart';
import '../widgets/sticker_picker_sheet.dart';
import '../widgets/text_editor_sheet.dart';
import '../widgets/tool_dock.dart';

final _log = AppLogger('EditorPage');

class EditorPage extends ConsumerStatefulWidget {
  const EditorPage({required this.sourcePath, super.key});

  final String sourcePath;

  @override
  ConsumerState<EditorPage> createState() => _EditorPageState();
}

class _EditorPageState extends ConsumerState<EditorPage> {
  EditorNotifier? _notifier;
  bool _drawMode = false;
  /// When non-null, draw mode was entered for inpainting — the resolved
  /// LaMa model is stashed here so _onDrawDone can run inference.
  ResolvedModel? _pendingInpaintResolved;
  static const Uuid _uuid = Uuid();

  /// True while any AI inference is running. Guards against rapid
  /// re-taps (popup menu doesn't auto-dismiss on a second tap, and
  /// without this flag a user could stack two "Smooth skin" runs
  /// that both spawn their own ML Kit detector, both push progress
  /// dialogs on top of each other, and both commit layers). The
  /// flag is read by [_OverflowMenu] to visually disable the AI entries
  /// and checked inside each handler as a hard guard so even a
  /// menu-state-staleness case can't double-fire.
  bool _aiBusy = false;

  /// Always reset the [_aiBusy] flag. The mutation is unconditional
  /// (so a stale `true` can't survive even if the State outlives the
  /// inference future, which it shouldn't but defense-in-depth), and
  /// only the rebuild is gated on [mounted]. Keeps every AI flow's
  /// finally-block one line.
  void _clearAiBusy() {
    _aiBusy = false;
    if (mounted) setState(() {});
  }

  /// Disposer for the shader-failure listener so we can detach on
  /// page teardown.
  void Function()? _shaderFailureDisposer;

  @override
  void initState() {
    super.initState();
    _log.i('initState', {'path': widget.sourcePath});
    _notifier = ref.read(editorNotifierProvider.notifier);
    _shaderFailureDisposer =
        ShaderRegistry.instance.addFailureListener(_onShaderLoadFailure);
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      _notifier?.openSession(widget.sourcePath);
      if (!mounted) return;
      if (await FirstRunFlag.shouldShow(OnboardingKeys.editorOnboarding)) {
        if (!mounted) return;
        await _showOnboarding();
      }
    });
  }

  void _onShaderLoadFailure(String assetKey) {
    if (!mounted) return;
    // The renderer would silently skip the failing pass; tell the user
    // a single time per shader so a missing asset doesn't look like
    // their slider does nothing. Asset key is the relative path —
    // useful in a bug report.
    UserFeedback.error(
      context,
      'Effect unavailable: $assetKey could not load. The pass was '
      'skipped — please report this with your device model.',
    );
  }

  @override
  void dispose() {
    _log.i('dispose, closing session');
    _shaderFailureDisposer?.call();
    _shaderFailureDisposer = null;
    _notifier?.closeSession();
    _notifier = null;
    super.dispose();
  }

  Future<void> _showOnboarding() async {
    _log.i('show onboarding dialog');
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => const _OnboardingDialog(),
    );
    await FirstRunFlag.markSeen(OnboardingKeys.editorOnboarding);
  }

  Future<bool> _confirmExit() async {
    // Use this dialog when the user backs out with uncommitted edits.
    // The export pipeline writes a separate file via the share sheet;
    // exiting here drops the in-memory pipeline state. Phase 12 will
    // add proper project save/load on top.
    final result = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Exit editor?'),
        content: const Text(
          'Your edits will be discarded if you leave without exporting. '
          'Tap Export to save a copy first.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Stay'),
          ),
          FilledButton.tonal(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Discard & exit'),
          ),
        ],
      ),
    );
    return result ?? false;
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(editorNotifierProvider);
    return PopScope(
      canPop: state is EditorIdle || state is EditorError,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        final session = (state is EditorReady) ? state.session : null;
        final hasEdits =
            session != null && session.committedPipeline.operations.isNotEmpty;
        if (!hasEdits) {
          if (!mounted) return;
          Navigator.of(context).pop();
          return;
        }
        final navigator = Navigator.of(context);
        final confirmed = await _confirmExit();
        if (confirmed && mounted) {
          navigator.pop();
        }
      },
      child: Scaffold(
        appBar: _drawMode && state is EditorReady
            ? AppBar(
                leading: IconButton(
                  tooltip: 'Cancel drawing',
                  icon: const Icon(Icons.close),
                  onPressed: _onExitDraw,
                ),
                title: const Text('Draw'),
              )
            : AppBar(
                leading: IconButton(
                  tooltip: 'Back',
                  icon: const Icon(Icons.arrow_back, size: 22),
                  onPressed: () => _onBack(state),
                  visualDensity: VisualDensity.compact,
                ),
                titleSpacing: 0,
                title: _EditorTitle(
                  // The session may not be ready yet (loading / idle /
                  // error) — fall back to the path on the widget so the
                  // bar still shows context.
                  fileName: _basenameOf(widget.sourcePath),
                ),
                actions: [
                  if (state is EditorReady) ...[
                    // Primary creative actions — left to right by
                    // frequency of use.
                    IconButton(
                      tooltip: 'Auto enhance',
                      icon: const Icon(Icons.auto_fix_high, size: 20),
                      visualDensity: VisualDensity.compact,
                      onPressed: () => _onAutoEnhance(state.session),
                    ),
                    IconButton(
                      tooltip: 'Presets',
                      icon: const Icon(Icons.auto_awesome_mosaic_outlined,
                          size: 20),
                      visualDensity: VisualDensity.compact,
                      onPressed: () => _showPresetsSheet(state.session),
                    ),
                    _AddLayerMenu(
                      onText: () => _onAddText(state.session),
                      onSticker: () => _onAddSticker(state.session),
                      onDraw: _onEnterDraw,
                    ),
                    IconButton(
                      tooltip: 'Layers',
                      icon: const Icon(Icons.layers_outlined, size: 20),
                      visualDensity: VisualDensity.compact,
                      onPressed: () => _showLayersSheet(state.session),
                    ),
                    BeforeAfterToggle(session: state.session),
                    IconButton(
                      tooltip: 'Open another photo',
                      icon: const Icon(Icons.photo_library_outlined, size: 20),
                      visualDensity: VisualDensity.compact,
                      onPressed: () => _onOpenAnother(state),
                    ),
                    IconButton(
                      tooltip: 'Export / Save',
                      icon: const Icon(Icons.ios_share, size: 20),
                      visualDensity: VisualDensity.compact,
                      onPressed: () =>
                          ExportSheet.show(context, state.session),
                    ),
                    // Overflow + undo/redo always go at the end.
                    _OverflowMenu(
                      aiBusy: _aiBusy,
                      onRemoveBackground: () =>
                          _onRemoveBackground(state.session),
                      onSmoothSkin: () => _onSmoothSkin(state.session),
                      onBrightenEyes: () => _onBrightenEyes(state.session),
                      onWhitenTeeth: () => _onWhitenTeeth(state.session),
                      onSculptFace: () => _onSculptFace(state.session),
                      onReplaceSky: () => _onReplaceSky(state.session),
                      onRemoveObject: () => _onRemoveObject(state.session),
                      onEnhance: () => _onEnhance(state.session),
                      onStyleTransfer: () => _onStyleTransfer(state.session),
                      onManageModels: () => ModelManagerSheet.show(context),
                      onReset: () => _onResetAll(state.session),
                      onHelp: _showOnboarding,
                    ),
                  ],
                  const _UndoRedoBar(),
                ],
              ),
        body: _drawMode && state is EditorReady
            ? DrawModeOverlay(
                source: state.session.sourceImage,
                geometry: state.session.previewController.geometry.value,
                newLayerId: _uuid.v4(),
                onDone: (layer) => _onDrawingDone(state.session, layer),
                onCancel: _onExitDraw,
              )
            : switch (state) {
                EditorIdle() =>
                  const _LoadingView(message: 'Starting session...'),
                EditorLoading() =>
                  const _LoadingView(message: 'Loading photo...'),
                EditorError(:final message) => _ErrorView(
                    message: message,
                    onRetry: () => _notifier?.openSession(widget.sourcePath),
                  ),
                EditorReady(:final session) =>
                  _EditorBody(session: session),
              },
      ),
    );
  }

  /// True when the session has committed edits that would be lost on exit.
  bool _hasEdits(EditorState state) {
    if (state is! EditorReady) return false;
    return state.session.committedPipeline.operations.isNotEmpty;
  }

  /// Prompt the user if there are unsaved edits. Returns true to
  /// proceed, false to cancel.
  Future<bool> _maybePromptSave(EditorState state) async {
    if (!_hasEdits(state)) return true;
    return _confirmExit();
  }

  /// Leading back button — prompts to save then pops to home.
  Future<void> _onBack(EditorState state) async {
    _log.i('back tapped');
    Haptics.tap();
    final ok = await _maybePromptSave(state);
    if (!ok || !mounted) return;
    // GoRouter pop falls back to replacing with '/' if there's nothing
    // to pop to (e.g. deep link).
    if (Navigator.of(context).canPop()) {
      Navigator.of(context).pop();
    } else {
      context.go('/');
    }
  }

  /// "Open another photo" action — picks a new image then swaps the
  /// session, prompting to discard current edits first.
  Future<void> _onOpenAnother(EditorState state) async {
    _log.i('open another tapped');
    Haptics.tap();
    final ok = await _maybePromptSave(state);
    if (!ok || !mounted) return;
    final picker = ImagePicker();
    final picked = await picker.pickImage(source: ImageSource.gallery);
    if (picked == null || !mounted) return;
    _log.i('swapping session', {'to': picked.path});
    // Re-open the editor with the new path. openSession will close the
    // current session cleanly before loading the new proxy.
    await _notifier?.openSession(picked.path);
  }

  Future<void> _onAutoEnhance(EditorSession session) async {
    _log.i('auto enhance tapped');
    Haptics.tap();
    bool ok = false;
    try {
      ok = await session.applyAuto(AutoFixScope.all);
    } catch (e, st) {
      _log.e('auto enhance failed', error: e, stackTrace: st);
      if (!mounted) return;
      Haptics.warning();
      UserFeedback.error(context, 'Auto enhance failed: $e');
      return;
    }
    if (!mounted) return;
    UserFeedback.info(
      context,
      ok
          ? 'Auto enhance applied — tweak any slider to refine'
          : 'The photo already looks balanced',
    );
  }

  Future<void> _onResetAll(EditorSession session) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Reset all adjustments?'),
        content: const Text(
          'This undoes every edit in the pipeline. You can redo afterwards.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton.tonal(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Reset'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    _log.i('reset all confirmed');
    Haptics.impact();
    session.resetAll();
    if (!mounted) return;
    UserFeedback.info(context, 'Adjustments reset');
  }

  Future<void> _onAddText(EditorSession session) async {
    _log.i('add text tapped');
    Haptics.tap();
    final id = _uuid.v4();
    final layer = await TextEditorSheet.show(context, id: id);
    if (layer == null) return;
    session.addLayer(layer);
    // Auto-select so the user can immediately drag / pinch the new
    // text into place without a second tap.
    session.selectLayer(layer.id);
    if (!mounted) return;
    UserFeedback.success(context, 'Text added — drag to move, pinch to resize');
  }

  Future<void> _onAddSticker(EditorSession session) async {
    _log.i('add sticker tapped');
    Haptics.tap();
    final id = _uuid.v4();
    final layer = await StickerPickerSheet.show(context, id: id);
    if (layer == null) return;
    session.addLayer(layer);
    session.selectLayer(layer.id);
    if (!mounted) return;
    UserFeedback.success(
        context, 'Sticker added — drag to move, pinch to resize');
  }

  void _onEnterDraw() {
    _log.i('enter draw mode');
    Haptics.tap();
    setState(() => _drawMode = true);
  }

  void _onExitDraw() {
    _log.i('exit draw mode');
    setState(() {
      _drawMode = false;
      _pendingInpaintResolved = null;
    });
  }

  void _onDrawingDone(EditorSession session, DrawingLayer layer) {
    // If we're in inpaint mode, use the strokes as an inpaint mask.
    if (_pendingInpaintResolved != null) {
      _runInpaintFromStrokes(session, layer);
      return;
    }
    session.addLayer(layer);
    setState(() => _drawMode = false);
    if (!mounted) return;
    UserFeedback.success(
        context, 'Drawing added (${layer.strokes.length} strokes)');
  }

  Future<void> _onRemoveBackground(EditorSession session) async {
    _log.i('remove background tapped');
    Haptics.tap();
    if (_aiBusy) {
      _log.w('remove background rejected — another AI op is running');
      return;
    }
    // Phase 9c: show the strategy picker first so the user can choose
    // MediaPipe (fast, bundled), MODNet (balanced, ~7 MB download), or
    // RMBG (best, ~44 MB download). The sheet handles downloads inline.
    //
    // NOTE: we do NOT set _aiBusy=true here — the picker sheet + model
    // download flow is its own UX, and blocking the AI menu while the
    // user is still deciding would be surprising. The flag only flips
    // once the user picks a strategy and we start the actual inference.
    final factory = ref.read(bgRemovalFactoryProvider);
    final registry = ref.read(modelRegistryProvider);
    final downloader = ref.read(modelDownloaderProvider);
    final kind = await BgRemovalPickerSheet.show(
      context,
      factory: factory,
      registry: registry,
      downloader: downloader,
    );
    if (kind == null) {
      _log.i('remove background cancelled');
      return;
    }
    if (!mounted) return;
    if (_aiBusy) {
      // Rare: user opened the picker, another AI op started via some
      // other path (shouldn't happen today but defense-in-depth), the
      // user picked a strategy. Abort before we spin up resources.
      _log.w('remove background rejected post-picker — AI op is running');
      return;
    }
    setState(() => _aiBusy = true);
    _log.i('remove background strategy chosen', {'kind': kind.name});

    final messenger = ScaffoldMessenger.of(context);

    // Build the strategy FIRST (may throw on wrong runtime / missing
    // model). We don't want the progress dialog visible during this
    // error path because popping a not-yet-shown dialog would pop the
    // editor route instead (classic `showDialog` + pre-await race).
    BgRemovalStrategy? strategy;
    try {
      strategy = await factory.create(kind);
    } on BgRemovalException catch (e) {
      _log.w('bg removal factory failed',
          {'error': e.message, 'kind': e.kind?.name});
      _clearAiBusy();
      if (!mounted) return;
      Haptics.warning();
      messenger.showSnackBar(
        SnackBar(content: Text('Background removal failed: ${e.message}')),
      );
      return;
    }
    if (!mounted) {
      await strategy.close();
      _clearAiBusy();
      return;
    }

    final navigator = Navigator.of(context, rootNavigator: true);
    // Now that the strategy is ready, show the progress dialog and
    // run inference. barrier-dismissible: false so the user can't
    // race ahead and dispatch another AI action during inference.
    // A `_DialogHandle` tracks whether the dialog has actually been
    // popped so error/success paths don't double-pop.
    final dialogHandle = _DialogHandle();
    unawaited(
      showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (_) => _AiProgressDialog(
          title: 'Removing background',
          subtitle: _subtitleFor(kind),
        ),
      ).whenComplete(dialogHandle.markClosed),
    );

    try {
      final layerId = _uuid.v4();
      await session.applyBackgroundRemoval(
        strategy: strategy,
        newLayerId: layerId,
      );
      dialogHandle.pop(navigator);
      if (!mounted) return;
      Haptics.impact();
      UserFeedback.success(context, 'Background removed (${kind.label})');
    } on BgRemovalException catch (e) {
      _log.w('bg removal failed', {'error': e.message, 'kind': e.kind?.name});
      dialogHandle.pop(navigator);
      if (!mounted) return;
      Haptics.warning();
      messenger.showSnackBar(
        SnackBar(content: Text('Background removal failed: ${e.message}')),
      );
    } catch (e, st) {
      _log.e('bg removal unexpected error', error: e, stackTrace: st);
      dialogHandle.pop(navigator);
      if (!mounted) return;
      Haptics.warning();
      UserFeedback.error(context, 'Unexpected error: $e');
    } finally {
      await strategy.close();
      _clearAiBusy();
    }
  }

  String _subtitleFor(BgRemovalStrategyKind kind) {
    switch (kind) {
      case BgRemovalStrategyKind.mediaPipe:
        return 'Running MediaPipe selfie segmentation…';
      case BgRemovalStrategyKind.modnet:
        return 'Running MODNet portrait matting…';
      case BgRemovalStrategyKind.rmbg:
        return 'Running RMBG-1.4 general matting…';
      case BgRemovalStrategyKind.generalOffline:
        return 'Running U²-Netp offline matting…';
    }
  }

  Future<void> _onSmoothSkin(EditorSession session) async {
    _log.i('smooth skin tapped');
    Haptics.tap();
    if (!mounted) return;
    if (_aiBusy) {
      _log.w('smooth skin rejected — another AI op is running');
      return;
    }
    setState(() => _aiBusy = true);

    // Construct the detector + service BEFORE showing the progress
    // dialog. Matches the 9c audit fix for bg removal: if anything
    // about initialization throws synchronously we don't leak a
    // dialog. ML Kit's detector constructor is currently a pure
    // field assignment, but wrapping in try/catch means a future
    // native dep swap can't strand the _aiBusy flag.
    final FaceDetectionService detector;
    final PortraitSmoothService service;
    try {
      detector = FaceDetectionService(enableContours: true);
      service = PortraitSmoothService(detector: detector);
    } catch (e, st) {
      _log.e('smooth skin: service construction failed',
          error: e, stackTrace: st);
      _clearAiBusy();
      if (mounted) {
        Haptics.warning();
        UserFeedback.error(context, 'Could not start skin smoothing: $e');
      }
      return;
    }

    final messenger = ScaffoldMessenger.of(context);
    final navigator = Navigator.of(context, rootNavigator: true);
    final dialogHandle = _DialogHandle();
    unawaited(
      showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (_) => const _AiProgressDialog(
          title: 'Smoothing skin',
          subtitle: 'Detecting faces and softening skin…',
        ),
      ).whenComplete(dialogHandle.markClosed),
    );

    try {
      final layerId = _uuid.v4();
      await session.applyPortraitSmooth(
        service: service,
        newLayerId: layerId,
      );
      dialogHandle.pop(navigator);
      if (!mounted) return;
      Haptics.impact();
      UserFeedback.success(context, 'Portrait smoothed');
    } on PortraitSmoothException catch (e) {
      _log.w('smooth skin failed', {'error': e.message});
      dialogHandle.pop(navigator);
      if (!mounted) return;
      Haptics.warning();
      messenger.showSnackBar(
        SnackBar(content: Text('Portrait smoothing failed: ${e.message}')),
      );
    } catch (e, st) {
      _log.e('smooth skin unexpected error', error: e, stackTrace: st);
      dialogHandle.pop(navigator);
      if (!mounted) return;
      Haptics.warning();
      UserFeedback.error(context, 'Unexpected error: $e');
    } finally {
      await service.close();
      await detector.close();
      _clearAiBusy();
    }
  }

  Future<void> _onBrightenEyes(EditorSession session) async {
    _log.i('brighten eyes tapped');
    Haptics.tap();
    if (!mounted) return;
    if (_aiBusy) {
      _log.w('brighten eyes rejected — another AI op is running');
      return;
    }
    setState(() => _aiBusy = true);

    final FaceDetectionService detector;
    final EyeBrightenService service;
    try {
      detector = FaceDetectionService(enableContours: true);
      service = EyeBrightenService(detector: detector);
    } catch (e, st) {
      _log.e('brighten eyes: service construction failed',
          error: e, stackTrace: st);
      _clearAiBusy();
      if (mounted) {
        Haptics.warning();
        UserFeedback.error(context, 'Could not start eye brightening: $e');
      }
      return;
    }

    final messenger = ScaffoldMessenger.of(context);
    final navigator = Navigator.of(context, rootNavigator: true);
    final dialogHandle = _DialogHandle();
    unawaited(
      showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (_) => const _AiProgressDialog(
          title: 'Brightening eyes',
          subtitle: 'Detecting eye landmarks…',
        ),
      ).whenComplete(dialogHandle.markClosed),
    );

    try {
      final layerId = _uuid.v4();
      await session.applyEyeBrighten(
        service: service,
        newLayerId: layerId,
      );
      dialogHandle.pop(navigator);
      if (!mounted) return;
      Haptics.impact();
      UserFeedback.success(context, 'Eyes brightened');
    } on EyeBrightenException catch (e) {
      _log.w('brighten eyes failed', {'error': e.message});
      dialogHandle.pop(navigator);
      if (!mounted) return;
      Haptics.warning();
      messenger.showSnackBar(
        SnackBar(content: Text('Eye brightening failed: ${e.message}')),
      );
    } catch (e, st) {
      _log.e('brighten eyes unexpected error',
          error: e, stackTrace: st);
      dialogHandle.pop(navigator);
      if (!mounted) return;
      Haptics.warning();
      UserFeedback.error(context, 'Unexpected error: $e');
    } finally {
      await service.close();
      await detector.close();
      _clearAiBusy();
    }
  }

  Future<void> _onWhitenTeeth(EditorSession session) async {
    _log.i('whiten teeth tapped');
    Haptics.tap();
    if (!mounted) return;
    if (_aiBusy) {
      _log.w('whiten teeth rejected — another AI op is running');
      return;
    }
    setState(() => _aiBusy = true);

    final FaceDetectionService detector;
    final TeethWhitenService service;
    try {
      detector = FaceDetectionService(enableContours: true);
      service = TeethWhitenService(detector: detector);
    } catch (e, st) {
      _log.e('whiten teeth: service construction failed',
          error: e, stackTrace: st);
      _clearAiBusy();
      if (mounted) {
        Haptics.warning();
        UserFeedback.error(context, 'Could not start teeth whitening: $e');
      }
      return;
    }

    final messenger = ScaffoldMessenger.of(context);
    final navigator = Navigator.of(context, rootNavigator: true);
    final dialogHandle = _DialogHandle();
    unawaited(
      showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (_) => const _AiProgressDialog(
          title: 'Whitening teeth',
          subtitle: 'Detecting mouth landmarks…',
        ),
      ).whenComplete(dialogHandle.markClosed),
    );

    try {
      final layerId = _uuid.v4();
      await session.applyTeethWhiten(
        service: service,
        newLayerId: layerId,
      );
      dialogHandle.pop(navigator);
      if (!mounted) return;
      Haptics.impact();
      UserFeedback.success(context, 'Teeth whitened');
    } on TeethWhitenException catch (e) {
      _log.w('whiten teeth failed', {'error': e.message});
      dialogHandle.pop(navigator);
      if (!mounted) return;
      Haptics.warning();
      messenger.showSnackBar(
        SnackBar(content: Text('Teeth whitening failed: ${e.message}')),
      );
    } catch (e, st) {
      _log.e('whiten teeth unexpected error', error: e, stackTrace: st);
      dialogHandle.pop(navigator);
      if (!mounted) return;
      Haptics.warning();
      UserFeedback.error(context, 'Unexpected error: $e');
    } finally {
      await service.close();
      await detector.close();
      _clearAiBusy();
    }
  }

  /// Default reshape parameters for the one-shot "Sculpt face"
  /// menu entry. Persisted on the [AdjustmentLayer] so a future
  /// reload path can re-run the warp with the same strengths.
  /// Keep conservative — the warp moves background pixels near
  /// the face contour, and large strengths start to look
  /// uncanny. A future slider UI can override these.
  static const Map<String, double> _defaultReshapeParams = {
    'slim': 0.3,
    'eyes': 0.15,
  };

  Future<void> _onSculptFace(EditorSession session) async {
    _log.i('sculpt face tapped');
    Haptics.tap();
    if (!mounted) return;
    if (_aiBusy) {
      _log.w('sculpt face rejected — another AI op is running');
      return;
    }
    setState(() => _aiBusy = true);

    // Face reshape needs a CONTOUR-enabled detector (unlike the
    // 9d/9e beauty ops which only need landmarks). Build a fresh
    // one per invocation with the contour flag flipped.
    //
    // Constructors are wrapped so a future native-dep swap can't
    // strand the _aiBusy flag if one of them throws synchronously.
    // Both flavors today are pure field init, but the wrapping is
    // cheap insurance against a repeat of the 9c pre-audit race.
    final FaceDetectionService detector;
    final FaceReshapeService service;
    try {
      detector = FaceDetectionService(enableContours: true);
      service = FaceReshapeService(
        detector: detector,
        slimFaceStrength: _defaultReshapeParams['slim']!,
        enlargeEyesStrength: _defaultReshapeParams['eyes']!,
      );
    } catch (e, st) {
      _log.e('sculpt face: service construction failed',
          error: e, stackTrace: st);
      _clearAiBusy();
      if (mounted) {
        Haptics.warning();
        UserFeedback.error(context, 'Could not start face reshape: $e');
      }
      return;
    }

    final messenger = ScaffoldMessenger.of(context);
    final navigator = Navigator.of(context, rootNavigator: true);
    final dialogHandle = _DialogHandle();
    unawaited(
      showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (_) => const _AiProgressDialog(
          title: 'Sculpting face',
          subtitle: 'Detecting face contours and warping…',
        ),
      ).whenComplete(dialogHandle.markClosed),
    );

    try {
      final layerId = _uuid.v4();
      await session.applyFaceReshape(
        service: service,
        newLayerId: layerId,
        reshapeParams: _defaultReshapeParams,
      );
      dialogHandle.pop(navigator);
      if (!mounted) return;
      Haptics.impact();
      UserFeedback.success(context, 'Face sculpted');
    } on FaceReshapeException catch (e) {
      _log.w('sculpt face failed', {'error': e.message});
      dialogHandle.pop(navigator);
      if (!mounted) return;
      Haptics.warning();
      messenger.showSnackBar(
        SnackBar(content: Text('Face reshape failed: ${e.message}')),
      );
    } catch (e, st) {
      _log.e('sculpt face unexpected error', error: e, stackTrace: st);
      dialogHandle.pop(navigator);
      if (!mounted) return;
      Haptics.warning();
      UserFeedback.error(context, 'Unexpected error: $e');
    } finally {
      await service.close();
      await detector.close();
      _clearAiBusy();
    }
  }

  Future<void> _onReplaceSky(EditorSession session) async {
    _log.i('replace sky tapped');
    Haptics.tap();
    if (_aiBusy) {
      _log.w('replace sky rejected — another AI op is running');
      return;
    }
    // Show the preset picker FIRST so the user can choose a sky
    // mood before we do any work. Same UX as the bg removal
    // picker: the picker itself doesn't flip `_aiBusy`, because
    // blocking the AI menu while the user is still picking a
    // preset would be surprising — the flag only flips when we
    // actually start inference.
    final preset = await SkyReplacePickerSheet.show(context);
    if (preset == null) {
      _log.i('replace sky cancelled');
      return;
    }
    if (!mounted) return;
    if (_aiBusy) {
      _log.w('replace sky rejected post-picker — AI op is running');
      return;
    }
    setState(() => _aiBusy = true);
    _log.i('replace sky preset chosen', {'preset': preset.name});

    // SkyReplaceService has no native handles today — it's just
    // tuning params + pure Dart. The try/catch is insurance
    // against a future variant that does touch native resources:
    // if the constructor throws we MUST reset _aiBusy and surface
    // the error, or the menu stays dead forever.
    final SkyReplaceService service;
    try {
      service = SkyReplaceService();
    } catch (e, st) {
      _log.e('replace sky: service construction failed',
          error: e, stackTrace: st);
      _clearAiBusy();
      if (mounted) {
        Haptics.warning();
        UserFeedback.error(context, 'Could not start sky replacement: $e');
      }
      return;
    }

    final messenger = ScaffoldMessenger.of(context);
    final navigator = Navigator.of(context, rootNavigator: true);
    final dialogHandle = _DialogHandle();
    unawaited(
      showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (_) => _AiProgressDialog(
          title: 'Replacing sky',
          subtitle: 'Finding sky region and painting ${preset.label}…',
        ),
      ).whenComplete(dialogHandle.markClosed),
    );

    try {
      final layerId = _uuid.v4();
      await session.applySkyReplace(
        service: service,
        newLayerId: layerId,
        preset: preset,
      );
      dialogHandle.pop(navigator);
      if (!mounted) return;
      Haptics.impact();
      UserFeedback.success(context, 'Sky replaced (${preset.label})');
    } on SkyReplaceException catch (e) {
      _log.w('replace sky failed', {'error': e.message});
      dialogHandle.pop(navigator);
      if (!mounted) return;
      Haptics.warning();
      messenger.showSnackBar(
        SnackBar(content: Text('Sky replacement failed: ${e.message}')),
      );
    } catch (e, st) {
      _log.e('replace sky unexpected error', error: e, stackTrace: st);
      dialogHandle.pop(navigator);
      if (!mounted) return;
      Haptics.warning();
      UserFeedback.error(context, 'Unexpected error: $e');
    } finally {
      await service.close();
      _clearAiBusy();
    }
  }

  // ---- New AI features: Enhance, Style Transfer, Remove Object ----

  Future<void> _onEnhance(EditorSession session) async {
    _log.i('enhance tapped');
    Haptics.tap();
    if (!mounted) return;

    // Apply an "Enhance" preset: sharpening + clarity + slight
    // contrast + vibrance boost. This uses the existing shader
    // pipeline at full resolution — no model download needed.
    final enhancePreset = Preset(
      id: 'ai.enhance',
      name: 'Enhance',
      category: 'AI',
      builtIn: true,
      operations: [
        EditOperation.create(
          type: EditOpType.sharpen,
          parameters: {'amount': 0.2, 'radius': 0.8},
        ),
        EditOperation.create(
          type: EditOpType.clarity,
          parameters: {'value': 0.15},
        ),
        EditOperation.create(
          type: EditOpType.contrast,
          parameters: {'value': 0.05},
        ),
        EditOperation.create(
          type: EditOpType.vibrance,
          parameters: {'value': 0.1},
        ),
        EditOperation.create(
          type: EditOpType.highlights,
          parameters: {'value': -0.05},
        ),
        EditOperation.create(
          type: EditOpType.shadows,
          parameters: {'value': 0.05},
        ),
      ],
    );
    session.applyPreset(enhancePreset);
    if (!mounted) return;
    Haptics.impact();
    UserFeedback.success(context, 'Image enhanced');
  }

  Future<void> _onStyleTransfer(EditorSession session) async {
    _log.i('style transfer tapped');
    Haptics.tap();
    if (!mounted) return;
    if (_aiBusy) return;

    // Show bottom sheet: gallery pick OR use current photo as self-style.
    final choice = await showModalBottomSheet<String>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Padding(
              padding: EdgeInsets.all(Spacing.md),
              child: Text('Style Transfer',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
            ),
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: Spacing.lg),
              child: Text(
                'Pick any photo to use as a style reference — paintings, textures, or patterns work best.',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 13, color: Colors.grey),
              ),
            ),
            const SizedBox(height: Spacing.md),
            ListTile(
              leading: const CircleAvatar(child: Icon(Icons.photo_library)),
              title: const Text('Pick from gallery'),
              subtitle: const Text('Use any image as style reference'),
              onTap: () => Navigator.pop(ctx, 'gallery'),
            ),
            ListTile(
              leading: const CircleAvatar(child: Icon(Icons.camera_alt)),
              title: const Text('Take a photo'),
              subtitle: const Text('Capture a texture or pattern'),
              onTap: () => Navigator.pop(ctx, 'camera'),
            ),
            const SizedBox(height: Spacing.md),
          ],
        ),
      ),
    );
    if (choice == null || !mounted) return;

    final picker = ImagePicker();
    final picked = await picker.pickImage(
      source: choice == 'camera' ? ImageSource.camera : ImageSource.gallery,
      maxWidth: 512,
      maxHeight: 512,
    );
    if (picked == null || !mounted) return;
    final styleImagePath = picked.path;
    _log.i('style image picked', {'path': styleImagePath, 'source': choice});

    // Resolve both models.
    final registry = ref.read(modelRegistryProvider);
    final predictResolved = await registry.resolve('magenta_style_predict');
    final transferResolved = await registry.resolve('magenta_style_transfer');
    if (predictResolved == null || transferResolved == null) {
      if (!mounted) return;
      Haptics.warning();
      UserFeedback.error(context,
          'Style transfer models not available. Download them from AI Models.');
      return;
    }

    setState(() => _aiBusy = true);
    final liteRt = ref.read(liteRtRuntimeProvider);
    final navigator = Navigator.of(context, rootNavigator: true);
    final dialogHandle = _DialogHandle();
    unawaited(
      showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (_) => const _AiProgressDialog(
          title: 'Applying style',
          subtitle: 'Analyzing style and transferring…',
        ),
      ).whenComplete(dialogHandle.markClosed),
    );

    StylePredictService? predictService;
    StyleTransferService? transferService;
    try {
      // Step 1: Run prediction model to extract style vector.
      // Phase V.5: route through the sha256-keyed cache so a repeat
      // apply on the same reference image skips the ML Kit round-trip
      // entirely. Cache survives app restarts via `<AppDocs>/style_vectors/`.
      final predictSession = await liteRt.load(predictResolved);
      predictService = StylePredictService(session: predictSession);
      final styleCache = ref.read(styleVectorCacheProvider);
      final styleVector = await predictService.predictFromPath(
        styleImagePath,
        cache: styleCache,
      );
      await predictService.close();
      predictService = null;

      // Step 2: Run transfer model with real style vector.
      final transferSession = await liteRt.load(transferResolved);
      transferService = StyleTransferService(session: transferSession);
      final layerId = _uuid.v4();
      await session.applyStyleTransfer(
        service: transferService,
        styleVector: styleVector,
        styleName: 'Custom style',
        newLayerId: layerId,
      );
      dialogHandle.pop(navigator);
      if (!mounted) return;
      Haptics.impact();
      UserFeedback.success(context, 'Style applied');
    } on MlRuntimeException catch (e) {
      _log.w('style transfer model load failed', {'error': e.message});
      dialogHandle.pop(navigator);
      if (!mounted) return;
      Haptics.warning();
      UserFeedback.error(context, 'Model load failed: ${e.message}');
    } catch (e, st) {
      _log.e('style transfer unexpected error', error: e, stackTrace: st);
      dialogHandle.pop(navigator);
      if (!mounted) return;
      Haptics.warning();
      UserFeedback.error(context, 'Style transfer failed: $e');
    } finally {
      await predictService?.close();
      await transferService?.close();
      if (mounted) setState(() => _aiBusy = false);
    }
  }

  Future<void> _onRemoveObject(EditorSession session) async {
    _log.i('remove object tapped');
    Haptics.tap();
    if (!mounted) return;
    if (_aiBusy) return;

    // Resolve the LaMa model first.
    final registry = ref.read(modelRegistryProvider);
    final resolved = await registry.resolve('lama_inpaint');
    if (resolved == null) {
      if (!mounted) return;
      Haptics.warning();
      UserFeedback.error(context,
          'LaMa model not downloaded. Open AI Models to download it.');
      return;
    }

    // Enter a simplified draw mode for mask painting.
    // We reuse the draw mode overlay but instruct the user to paint
    // over the area to remove (white brush on black = inpaint mask).
    if (!mounted) return;
    UserFeedback.info(context,
        'Paint over the area you want to remove, then tap ✓');

    // Switch to draw mode temporarily to collect mask strokes.
    setState(() => _drawMode = true);
    // The user will paint strokes and press Done. We intercept the
    // result in _onExitDraw and check if we're in inpaint mode.
    _pendingInpaintResolved = resolved;
  }

  Future<void> _runInpaintFromStrokes(
      EditorSession session, DrawingLayer layer) async {
    final resolved = _pendingInpaintResolved!;
    setState(() {
      _drawMode = false;
      _pendingInpaintResolved = null;
      _aiBusy = true;
    });

    // Render the strokes into a mask bitmap.
    // We'll create a simple white-on-black mask from the stroke data.
    final srcW = session.sourceImage.width;
    final srcH = session.sourceImage.height;
    final maskRgba = _renderStrokesToMask(layer.strokes, srcW, srcH);

    final ortRuntime = ref.read(ortRuntimeProvider);
    final navigator = Navigator.of(context, rootNavigator: true);
    final dialogHandle = _DialogHandle();
    unawaited(
      showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (_) => const _AiProgressDialog(
          title: 'Removing object',
          subtitle: 'Filling in the masked area with LaMa…',
        ),
      ).whenComplete(dialogHandle.markClosed),
    );

    InpaintService? service;
    try {
      final ortSession = await ortRuntime.load(resolved);
      service = InpaintService(session: ortSession);
      final layerId = _uuid.v4();
      await session.applyInpainting(
        service: service,
        maskRgba: maskRgba,
        maskWidth: srcW,
        maskHeight: srcH,
        newLayerId: layerId,
      );
      dialogHandle.pop(navigator);
      if (!mounted) return;
      Haptics.impact();
      UserFeedback.success(context, 'Object removed');
    } on InpaintException catch (e) {
      _log.w('inpaint failed', {'error': e.message});
      dialogHandle.pop(navigator);
      if (!mounted) return;
      Haptics.warning();
      UserFeedback.error(context, 'Object removal failed: ${e.message}');
    } on MlRuntimeException catch (e) {
      _log.w('inpaint model load failed', {'error': e.message});
      dialogHandle.pop(navigator);
      if (!mounted) return;
      Haptics.warning();
      UserFeedback.error(context, 'Model load failed: ${e.message}');
    } catch (e, st) {
      _log.e('inpaint unexpected error', error: e, stackTrace: st);
      dialogHandle.pop(navigator);
      if (!mounted) return;
      Haptics.warning();
      UserFeedback.error(context, 'Unexpected error: $e');
    } finally {
      await service?.close();
      if (mounted) setState(() => _aiBusy = false);
    }
  }

  /// Rasterize drawing strokes into an RGBA mask bitmap.
  /// White (255,255,255,255) = area to inpaint, black = keep.
  static Uint8List _renderStrokesToMask(
      List<DrawingStroke> strokes, int width, int height) {
    final mask = Uint8List(width * height * 4); // all black (0,0,0,0)
    for (final stroke in strokes) {
      final r = (stroke.width / 2).ceil();
      for (final point in stroke.points) {
        final cx = (point.x * width).round();
        final cy = (point.y * height).round();
        // Paint a filled circle of radius r at (cx, cy).
        for (int dy = -r; dy <= r; dy++) {
          for (int dx = -r; dx <= r; dx++) {
            if (dx * dx + dy * dy > r * r) continue;
            final px = cx + dx;
            final py = cy + dy;
            if (px < 0 || px >= width || py < 0 || py >= height) continue;
            final idx = (py * width + px) * 4;
            mask[idx] = 255;
            mask[idx + 1] = 255;
            mask[idx + 2] = 255;
            mask[idx + 3] = 255;
          }
        }
      }
    }
    return mask;
  }

  void _showPresetsSheet(EditorSession session) {
    _log.i('open presets sheet');
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: false,
      useSafeArea: true,
      builder: (_) => Material(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        child: SafeArea(
          child: Padding(
            padding: const EdgeInsets.only(top: Spacing.md, bottom: Spacing.sm),
            child: PresetStrip(session: session),
          ),
        ),
      ),
    );
  }

  Future<void> _showLayersSheet(EditorSession session) async {
    _log.i('open layers sheet');
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (_) {
        return StreamBuilder<HistoryState>(
          stream: session.historyBloc.stream,
          initialData: session.historyBloc.state,
          builder: (context, snapshot) {
            final state = snapshot.data ?? session.historyBloc.state;
            return SizedBox(
              height: MediaQuery.sizeOf(context).height * 0.7,
              child: Column(
                children: [
                  Padding(
                    padding: const EdgeInsets.all(Spacing.md),
                    child: Row(
                      children: [
                        Text(
                          'Layers',
                          style: Theme.of(context).textTheme.titleLarge,
                        ),
                        const Spacer(),
                        IconButton(
                          tooltip: 'Close',
                          icon: const Icon(Icons.close),
                          onPressed: () => Navigator.of(context).pop(),
                        ),
                      ],
                    ),
                  ),
                  const Divider(height: 1),
                  Expanded(
                    child: SingleChildScrollView(
                      child: LayerStackPanel(
                        session: session,
                        state: state,
                      ),
                    ),
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }
}

class _LoadingView extends StatelessWidget {
  const _LoadingView({required this.message});
  final String message;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const CircularProgressIndicator(),
          const SizedBox(height: Spacing.lg),
          Text(message),
        ],
      ),
    );
  }
}

class _ErrorView extends StatelessWidget {
  const _ErrorView({required this.message, required this.onRetry});
  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(Spacing.xl),
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.error_outline, size: 56),
            const SizedBox(height: Spacing.md),
            Text(message, textAlign: TextAlign.center),
            const SizedBox(height: Spacing.lg),
            FilledButton.icon(
              icon: const Icon(Icons.refresh),
              label: const Text('Retry'),
              onPressed: onRetry,
            ),
          ],
        ),
      ),
    );
  }
}

class _EditorBody extends StatefulWidget {
  const _EditorBody({required this.session});
  final EditorSession session;

  @override
  State<_EditorBody> createState() => _EditorBodyState();
}

class _EditorBodyState extends State<_EditorBody> {
  bool _splitMode = false;
  OpCategory _category = OpCategory.light;

  void _toggleSplitMode() {
    _log.i('split mode toggled', {'next': !_splitMode});
    Haptics.tap();
    setState(() => _splitMode = !_splitMode);
  }

  @override
  Widget build(BuildContext context) {
    final session = widget.session;
    final canvas = _CanvasArea(
      session: session,
      splitMode: _splitMode,
      category: _category,
      onToggleSplit: _toggleSplitMode,
    );
    final panels = _PanelStack(
      session: session,
      category: _category,
      onCategoryChanged: (cat) => setState(() => _category = cat),
    );
    // Responsive split with three breakpoints:
    //   < 720 px or portrait → canvas-over-panels stack (phones).
    //   720–1100 px wide and landscape → canvas + 360 px right column
    //     (small tablets, landscape phones, foldables).
    //   ≥ 1100 px wide (large tablets, desktops) → canvas + 420 px
    //     right column with extra padding so the photo doesn't fight
    //     the panels for breathing room. Future enhancement could
    //     stack tools+panels horizontally for ultra-wide displays.
    return LayoutBuilder(
      builder: (context, constraints) {
        final w = constraints.maxWidth;
        final landscape = w > constraints.maxHeight;
        if (w < 720 || !landscape) {
          return Column(children: [Expanded(child: canvas), panels]);
        }
        final isLargeTablet = w >= 1100;
        final panelWidth = isLargeTablet ? 420.0 : 360.0;
        return Row(
          children: [
            Expanded(child: canvas),
            SizedBox(
              width: panelWidth,
              child: Material(
                color: Theme.of(context).colorScheme.surface,
                child: panels,
              ),
            ),
          ],
        );
      },
    );
  }
}

/// The canvas area: edited preview (or before/after split) + the
/// split-mode toggle and the dev perf HUD. Rendered as the dominant
/// region in both portrait and landscape layouts.
class _CanvasArea extends StatelessWidget {
  const _CanvasArea({
    required this.session,
    required this.splitMode,
    required this.category,
    required this.onToggleSplit,
  });

  final EditorSession session;
  final bool splitMode;
  final OpCategory category;
  final VoidCallback onToggleSplit;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(Spacing.lg),
      child: Stack(
        children: [
          splitMode
              ? BeforeAfterSplit(
                  source: session.sourceImage,
                  editedPasses: session.previewController.passes,
                  geometry: session.previewController.geometry,
                )
              : SnapseedGestureLayer(
                  session: session,
                  category: category,
                  child: ImageCanvas(
                    source: session.sourceImage,
                    passes: session.previewController.passes,
                    geometry: session.previewController.geometry,
                    layers: session.previewController.layers,
                    texturePool: session.texturePool,
                  ),
                ),
          // Stacks the vignette centre handle on top of the canvas
          // for the Effects tab. The widget is invisible (and its
          // gesture detector inert) when the vignette amount is
          // zero, so it never blocks the SnapseedGestureLayer's
          // pointer routing in other tabs.
          if (!splitMode && category == OpCategory.effects)
            Positioned.fill(
              child: VignetteCenterOverlay(session: session),
            ),
          Positioned(
            top: 8,
            left: 8,
            child: Material(
              color: Colors.black54,
              borderRadius: BorderRadius.circular(20),
              child: IconButton(
                tooltip: splitMode
                    ? 'Exit split view'
                    : 'Split view (drag to compare)',
                icon: Icon(
                  splitMode
                      ? Icons.view_agenda_outlined
                      : Icons.splitscreen,
                  color: Colors.white,
                ),
                onPressed: onToggleSplit,
              ),
            ),
          ),
          // Reads the persisted toggle so a user who turned it off
          // in Settings doesn't see it again on next launch. Self-
          // suppresses in release regardless.
          Consumer(
            builder: (_, ref, _) => PerfHud(
              enabled: ref.watch(perfHudEnabledProvider),
            ),
          ),
        ],
      ),
    );
  }
}

/// Preset strip + tool dock + per-category panel content. Lives in
/// the bottom slice of the portrait layout and the right column of
/// the landscape layout.
class _PanelStack extends StatelessWidget {
  const _PanelStack({
    required this.session,
    required this.category,
    required this.onCategoryChanged,
  });

  final EditorSession session;
  final OpCategory category;
  final ValueChanged<OpCategory> onCategoryChanged;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Material(
          color: Theme.of(context).colorScheme.surfaceContainerHighest,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              PresetStrip(session: session),
              const Divider(height: 1),
            ],
          ),
        ),
        StreamBuilder<HistoryState>(
          stream: session.historyBloc.stream,
          initialData: session.historyBloc.state,
          builder: (context, snapshot) {
            final historyState =
                snapshot.data ?? session.historyBloc.state;
            return ToolDock(
              active: category,
              activeCategories: historyState.pipeline.activeCategories,
              onCategoryChanged: onCategoryChanged,
              child: _CategoryContent(
                category: category,
                session: session,
                state: historyState,
              ),
            );
          },
        ),
      ],
    );
  }
}

/// The panel content that swaps with the active tool category. Color
/// gets a composite (main sliders + HSL + split toning), other
/// categories use the regular [LightroomPanel].
class _CategoryContent extends StatelessWidget {
  const _CategoryContent({
    required this.category,
    required this.session,
    required this.state,
  });

  final OpCategory category;
  final EditorSession session;
  final HistoryState state;

  @override
  Widget build(BuildContext context) {
    if (category == OpCategory.color) {
      return Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          LightroomPanel(
            category: category,
            session: session,
            state: state,
          ),
          const _SectionBreak(label: 'HSL'),
          HslPanel(session: session, state: state),
          const _SectionBreak(label: 'SPLIT TONING'),
          SplitToningPanel(session: session, state: state),
        ],
      );
    }
    if (category == OpCategory.geometry) {
      return GeometryPanel(session: session, state: state);
    }
    return LightroomPanel(
      category: category,
      session: session,
      state: state,
    );
  }
}

class _SectionBreak extends StatelessWidget {
  const _SectionBreak({required this.label});
  final String label;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        Spacing.lg,
        Spacing.lg,
        Spacing.lg,
        Spacing.xs,
      ),
      child: Row(
        children: [
          Expanded(child: Divider(color: theme.dividerColor)),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: Spacing.sm),
            child: Text(
              label,
              style: theme.textTheme.labelSmall?.copyWith(
                color: theme.colorScheme.primary,
                letterSpacing: 1.2,
              ),
            ),
          ),
          Expanded(child: Divider(color: theme.dividerColor)),
        ],
      ),
    );
  }
}

/// App bar menu for AI-powered actions.
///
/// - Phase 9b: Background removal (MediaPipe / MODNet / RMBG).
/// - Phase 9d: Smooth skin — face detection + face-masked blur.
/// - Phase 9e: Brighten eyes, whiten teeth — landmark-scoped RGB ops.
/// - Phase 9f: Sculpt face — contour-driven warp.
/// - Phase 9g: Replace sky — heuristic segmentation + procedural
///   gradient palette.
///
/// Later sub-phases (inpainting, super-resolution, etc.) keep
/// extending the same menu.
/// Two-line app-bar title showing "Editor" with the current file's
/// basename below, mirroring how Apple Photos / Google Photos surface
/// context. Falls back to just "Editor" when no file is loaded yet.
class _EditorTitle extends StatelessWidget {
  const _EditorTitle({required this.fileName});

  final String? fileName;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (fileName == null || fileName!.isEmpty) {
      return const Text('Editor');
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        const Text('Editor'),
        Text(
          fileName!,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ],
    );
  }
}

/// Strip the directory portion of a path/URI so the app bar shows
/// just `IMG_1234.jpg` instead of the full system path. Works for
/// both `/` and `\` separators and for `content://` URIs (returns
/// the segment after the last separator).
String? _basenameOf(String path) {
  if (path.isEmpty) return null;
  final cleaned = path.endsWith('/') || path.endsWith('\\')
      ? path.substring(0, path.length - 1)
      : path;
  final fwd = cleaned.lastIndexOf('/');
  final back = cleaned.lastIndexOf('\\');
  final cut = fwd > back ? fwd : back;
  if (cut < 0 || cut == cleaned.length - 1) return cleaned;
  return cleaned.substring(cut + 1);
}

/// Consolidated AppBar overflow menu — AI tools + Reset + Help.
/// The previous `_AiMenu` was split into this single entry-point so the
/// AppBar isn't overcrowded with three separate trigger icons.
class _OverflowMenu extends StatelessWidget {
  const _OverflowMenu({
    required this.aiBusy,
    required this.onRemoveBackground,
    required this.onSmoothSkin,
    required this.onBrightenEyes,
    required this.onWhitenTeeth,
    required this.onSculptFace,
    required this.onReplaceSky,
    required this.onRemoveObject,
    required this.onEnhance,
    required this.onStyleTransfer,
    required this.onManageModels,
    required this.onReset,
    required this.onHelp,
  });

  /// True while an AI inference is running. Grays out every AI
  /// action entry (Manage AI models stays enabled — it's just
  /// navigation and safe to open anytime). When [aiBusy] is true the
  /// trigger icon is also swapped for a small spinner so the user
  /// has a clear "something's running" signal even if the progress
  /// dialog is hidden behind something.
  final bool aiBusy;

  final VoidCallback onRemoveBackground;
  final VoidCallback onSmoothSkin;
  final VoidCallback onBrightenEyes;
  final VoidCallback onWhitenTeeth;
  final VoidCallback onSculptFace;
  final VoidCallback onReplaceSky;
  final VoidCallback onRemoveObject;
  final VoidCallback onEnhance;
  final VoidCallback onStyleTransfer;
  final VoidCallback onManageModels;
  final VoidCallback onReset;
  final VoidCallback onHelp;

  @override
  Widget build(BuildContext context) {
    return PopupMenuButton<String>(
      tooltip: aiBusy ? 'AI busy…' : 'More',
      icon: aiBusy
          ? const SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : const Icon(Icons.more_vert),
      onSelected: (value) {
        switch (value) {
          case 'bg_removal':
            onRemoveBackground();
            break;
          case 'smooth_skin':
            onSmoothSkin();
            break;
          case 'brighten_eyes':
            onBrightenEyes();
            break;
          case 'whiten_teeth':
            onWhitenTeeth();
            break;
          case 'sculpt_face':
            onSculptFace();
            break;
          case 'replace_sky':
            onReplaceSky();
            break;
          case 'remove_object':
            onRemoveObject();
            break;
          case 'enhance':
            onEnhance();
            break;
          case 'style_transfer':
            onStyleTransfer();
            break;
          case 'manage_models':
            onManageModels();
            break;
          case 'reset':
            onReset();
            break;
          case 'help':
            onHelp();
            break;
        }
      },
      itemBuilder: (_) => [
        PopupMenuItem(
          value: 'bg_removal',
          enabled: !aiBusy,
          child: const Row(
            children: [
              Icon(Icons.person_outline),
              SizedBox(width: Spacing.sm),
              Text('Remove background'),
            ],
          ),
        ),
        PopupMenuItem(
          value: 'smooth_skin',
          enabled: !aiBusy,
          child: const Row(
            children: [
              Icon(Icons.face_retouching_natural),
              SizedBox(width: Spacing.sm),
              Text('Smooth skin (portrait)'),
            ],
          ),
        ),
        PopupMenuItem(
          value: 'brighten_eyes',
          enabled: !aiBusy,
          child: const Row(
            children: [
              Icon(Icons.visibility_outlined),
              SizedBox(width: Spacing.sm),
              Text('Brighten eyes'),
            ],
          ),
        ),
        PopupMenuItem(
          value: 'whiten_teeth',
          enabled: !aiBusy,
          child: const Row(
            children: [
              Icon(Icons.sentiment_very_satisfied_outlined),
              SizedBox(width: Spacing.sm),
              Text('Whiten teeth'),
            ],
          ),
        ),
        PopupMenuItem(
          value: 'sculpt_face',
          enabled: !aiBusy,
          child: const Row(
            children: [
              Icon(Icons.face_outlined),
              SizedBox(width: Spacing.sm),
              Text('Sculpt face'),
            ],
          ),
        ),
        PopupMenuItem(
          value: 'replace_sky',
          enabled: !aiBusy,
          child: const Row(
            children: [
              Icon(Icons.wb_cloudy_outlined),
              SizedBox(width: Spacing.sm),
              Text('Replace sky'),
            ],
          ),
        ),
        PopupMenuItem(
          value: 'remove_object',
          enabled: !aiBusy,
          child: const Row(
            children: [
              Icon(Icons.auto_fix_high_outlined),
              SizedBox(width: Spacing.sm),
              Text('Remove object'),
            ],
          ),
        ),
        PopupMenuItem(
          value: 'enhance',
          enabled: !aiBusy,
          child: const Row(
            children: [
              Icon(Icons.auto_fix_high),
              SizedBox(width: Spacing.sm),
              Text('AI enhance'),
            ],
          ),
        ),
        PopupMenuItem(
          value: 'style_transfer',
          enabled: !aiBusy,
          child: const Row(
            children: [
              Icon(Icons.palette_outlined),
              SizedBox(width: Spacing.sm),
              Text('Style transfer (beta)'),
            ],
          ),
        ),
        const PopupMenuDivider(),
        const PopupMenuItem(
          value: 'manage_models',
          child: Row(
            children: [
              Icon(Icons.inventory_2_outlined),
              SizedBox(width: Spacing.sm),
              Text('Manage AI models'),
            ],
          ),
        ),
        const PopupMenuDivider(),
        const PopupMenuItem(
          value: 'reset',
          child: Row(
            children: [
              Icon(Icons.restart_alt),
              SizedBox(width: Spacing.sm),
              Text('Reset all adjustments'),
            ],
          ),
        ),
        const PopupMenuItem(
          value: 'help',
          child: Row(
            children: [
              Icon(Icons.help_outline),
              SizedBox(width: Spacing.sm),
              Text('Help'),
            ],
          ),
        ),
      ],
    );
  }
}

/// Tracks whether a modal progress dialog is still on the navigator
/// stack so we can safely [pop] it without risking a double-pop that
/// would accidentally close the editor underneath. Used by
/// [_onRemoveBackground] to coordinate the "show dialog + do async
/// work + handle result" lifecycle.
class _DialogHandle {
  bool _closed = false;

  void pop(NavigatorState navigator) {
    if (_closed) return;
    _closed = true;
    if (navigator.canPop()) {
      navigator.pop();
    }
  }

  void markClosed() {
    _closed = true;
  }
}

/// Modal progress dialog shown during AI inference. The user can't
/// dismiss it (barrierDismissible: false) so the session stays in
/// a consistent state while the model runs.
class _AiProgressDialog extends StatelessWidget {
  const _AiProgressDialog({
    required this.title,
    required this.subtitle,
  });

  final String title;
  final String subtitle;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AlertDialog(
      content: Row(
        children: [
          const SizedBox(
            width: 28,
            height: 28,
            child: CircularProgressIndicator(strokeWidth: 3),
          ),
          const SizedBox(width: Spacing.md),
          Expanded(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: theme.textTheme.titleSmall),
                const SizedBox(height: Spacing.xxs),
                Text(
                  subtitle,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// App bar overflow menu for adding content layers.
class _AddLayerMenu extends StatelessWidget {
  const _AddLayerMenu({
    required this.onText,
    required this.onSticker,
    required this.onDraw,
  });

  final VoidCallback onText;
  final VoidCallback onSticker;
  final VoidCallback onDraw;

  @override
  Widget build(BuildContext context) {
    return PopupMenuButton<String>(
      tooltip: 'Add text, sticker, or drawing',
      icon: const Icon(Icons.add),
      onSelected: (value) {
        switch (value) {
          case 'text':
            onText();
            break;
          case 'sticker':
            onSticker();
            break;
          case 'draw':
            onDraw();
            break;
        }
      },
      itemBuilder: (_) => const [
        PopupMenuItem(
          value: 'text',
          child: Row(
            children: [
              Icon(Icons.title),
              SizedBox(width: Spacing.sm),
              Text('Add text'),
            ],
          ),
        ),
        PopupMenuItem(
          value: 'sticker',
          child: Row(
            children: [
              Icon(Icons.emoji_emotions_outlined),
              SizedBox(width: Spacing.sm),
              Text('Add sticker'),
            ],
          ),
        ),
        PopupMenuItem(
          value: 'draw',
          child: Row(
            children: [
              Icon(Icons.brush_outlined),
              SizedBox(width: Spacing.sm),
              Text('Draw'),
            ],
          ),
        ),
      ],
    );
  }
}

class _UndoRedoBar extends ConsumerWidget {
  const _UndoRedoBar();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(editorNotifierProvider);
    if (state is! EditorReady) return const SizedBox.shrink();
    final bloc = state.session.historyBloc;
    return StreamBuilder<HistoryState>(
      stream: bloc.stream,
      initialData: bloc.state,
      builder: (context, snapshot) {
        final s = snapshot.data ?? bloc.state;
        final undoLabel = _opLabel(s.lastOpType);
        final redoLabel = _opLabel(s.nextOpType);
        return Row(
          children: [
            // Long-press the undo button to open the full history
            // timeline. Stays out of the way for the common case
            // (step-by-step undo via tap) and discoverable via
            // tooltip + first-launch onboarding.
            GestureDetector(
              onLongPress: s.entryCount > 0
                  ? () {
                      _log.i('history timeline opened');
                      Haptics.tap();
                      HistoryTimelineSheet.show(context, state.session);
                    }
                  : null,
              child: IconButton(
                tooltip: s.canUndo && undoLabel != null
                    ? 'Undo $undoLabel (long-press for history)'
                    : 'Undo (long-press for history)',
                icon: const Icon(Icons.undo, size: 20),
                visualDensity: VisualDensity.compact,
                onPressed: s.canUndo
                    ? () {
                        _log.i('undo tapped');
                        Haptics.tap();
                        bloc.add(const UndoEdit());
                        UserFeedback.info(
                          context,
                          undoLabel != null
                              ? 'Undone — $undoLabel'
                              : 'Undone',
                        );
                      }
                    : null,
              ),
            ),
            IconButton(
              tooltip:
                  s.canRedo && redoLabel != null ? 'Redo $redoLabel' : 'Redo',
              icon: const Icon(Icons.redo, size: 20),
              visualDensity: VisualDensity.compact,
              onPressed: s.canRedo
                  ? () {
                      _log.i('redo tapped');
                      Haptics.tap();
                      bloc.add(const RedoEdit());
                      UserFeedback.info(
                        context,
                        redoLabel != null
                            ? 'Redone — $redoLabel'
                            : 'Redone',
                      );
                    }
                  : null,
            ),
            const SizedBox(width: Spacing.sm),
          ],
        );
      },
    );
  }
}

// Phase X.A.1 — full lookup moved to
// `lib/engine/history/op_display_names.dart` as public
// `opDisplayLabel`. Kept as a one-line alias here so the rest of
// this page still uses `_opLabel(...)` at its call sites.
String? _opLabel(String? type) => opDisplayLabel(type);

/// First-run onboarding tour. Replaces the previous wall-of-tips
/// dialog with a 4-page carousel — easier to skim, easier to read on
/// small phones, and dedicates a slide to the new Crop / Erase tools
/// the wall couldn't fit. The Skip / Next / Done buttons sit in the
/// dialog's actions row so they stay aligned with Material 3.
class _OnboardingDialog extends StatefulWidget {
  const _OnboardingDialog();

  @override
  State<_OnboardingDialog> createState() => _OnboardingDialogState();
}

class _OnboardingDialogState extends State<_OnboardingDialog> {
  final PageController _pages = PageController();
  int _index = 0;

  static const List<_OnboardingPage> _kPages = [
    _OnboardingPage(
      icon: Icons.auto_fix_high,
      title: 'Welcome',
      body: 'A non-destructive editor — every change is reversible '
          "and your original photo is never modified. Let's walk "
          'through the basics.',
    ),
    _OnboardingPage(
      icon: Icons.swipe,
      title: 'Gestures',
      bullets: [
        ('One-finger drag on the photo', 'adjusts the active parameter'),
        ('Vertical flick on the photo', 'cycles between parameters'),
        ('Two-finger pinch', 'zooms the preview'),
        ('Hold the compare icon', 'shows the original'),
      ],
    ),
    _OnboardingPage(
      icon: Icons.dashboard_customize_outlined,
      title: 'Tools',
      bullets: [
        ('Light / Color / Effects / Detail', 'tabs at the bottom'),
        ('Presets strip', 'tap a tile to apply a look'),
        ('Crop & rotate', 'in the Geometry tab'),
        ('AI menu', 'sky replace, beautify, erase, more'),
      ],
    ),
    _OnboardingPage(
      icon: Icons.bookmark_outlined,
      title: 'Save & share',
      bullets: [
        ('Auto-save', 'sessions resume from the home recents strip'),
        ('Export sheet', 'share or save to Photos at any size'),
        ('History timeline', 'long-press undo to jump to any step'),
        ('Settings', 'theme, models, recent exports'),
      ],
    ),
  ];

  void _next() {
    if (_index >= _kPages.length - 1) {
      Navigator.of(context).pop();
      return;
    }
    Haptics.tap();
    _pages.nextPage(
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOutCubic,
    );
  }

  void _skip() {
    Haptics.tap();
    Navigator.of(context).pop();
  }

  @override
  void dispose() {
    _pages.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isLast = _index >= _kPages.length - 1;
    return Dialog(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420, maxHeight: 540),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(
            Spacing.xl,
            Spacing.xl,
            Spacing.xl,
            Spacing.md,
          ),
          child: Column(
            children: [
              SizedBox(
                height: 320,
                child: PageView.builder(
                  controller: _pages,
                  itemCount: _kPages.length,
                  onPageChanged: (i) => setState(() => _index = i),
                  itemBuilder: (_, i) => _OnboardingSlide(page: _kPages[i]),
                ),
              ),
              const SizedBox(height: Spacing.md),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  for (int i = 0; i < _kPages.length; i++)
                    AnimatedContainer(
                      duration: const Duration(milliseconds: 180),
                      width: i == _index ? 18 : 6,
                      height: 6,
                      margin: const EdgeInsets.symmetric(horizontal: 3),
                      decoration: BoxDecoration(
                        color: i == _index
                            ? theme.colorScheme.primary
                            : theme.colorScheme.outlineVariant,
                        borderRadius: BorderRadius.circular(3),
                      ),
                    ),
                ],
              ),
              const SizedBox(height: Spacing.sm),
              Row(
                children: [
                  TextButton(
                    onPressed: isLast ? null : _skip,
                    child: Text(isLast ? '' : 'Skip'),
                  ),
                  const Spacer(),
                  FilledButton(
                    onPressed: _next,
                    child: Text(isLast ? "Let's go" : 'Next'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// One slide of the onboarding carousel. Either a single body
/// paragraph (Welcome) or a list of (label, detail) bullet pairs.
class _OnboardingPage {
  const _OnboardingPage({
    required this.icon,
    required this.title,
    this.body,
    this.bullets = const [],
  });

  final IconData icon;
  final String title;
  final String? body;
  final List<(String label, String detail)> bullets;
}

class _OnboardingSlide extends StatelessWidget {
  const _OnboardingSlide({required this.page});
  final _OnboardingPage page;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 72,
          height: 72,
          decoration: BoxDecoration(
            color: theme.colorScheme.primaryContainer,
            shape: BoxShape.circle,
          ),
          alignment: Alignment.center,
          child: Icon(
            page.icon,
            size: 36,
            color: theme.colorScheme.onPrimaryContainer,
          ),
        ),
        const SizedBox(height: Spacing.md),
        Text(page.title, style: theme.textTheme.titleLarge),
        const SizedBox(height: Spacing.sm),
        if (page.body != null)
          Text(
            page.body!,
            textAlign: TextAlign.center,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          )
        else
          Expanded(
            child: ListView.separated(
              shrinkWrap: true,
              padding: EdgeInsets.zero,
              itemCount: page.bullets.length,
              separatorBuilder: (_, _) =>
                  const SizedBox(height: Spacing.sm),
              itemBuilder: (_, i) {
                final (label, detail) = page.bullets[i];
                return Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(
                      Icons.circle,
                      size: 6,
                      color: theme.colorScheme.primary,
                    ),
                    const SizedBox(width: Spacing.sm),
                    Expanded(
                      child: RichText(
                        text: TextSpan(
                          style: theme.textTheme.bodyMedium,
                          children: [
                            TextSpan(
                              text: label,
                              style: const TextStyle(
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            const TextSpan(text: ' — '),
                            TextSpan(
                              text: detail,
                              style: TextStyle(
                                color:
                                    theme.colorScheme.onSurfaceVariant,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                );
              },
            ),
          ),
      ],
    );
  }
}

