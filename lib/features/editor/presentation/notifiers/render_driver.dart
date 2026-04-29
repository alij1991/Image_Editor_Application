import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';

import '../../../../core/async/generation_guard.dart';
import '../../../../core/logging/app_logger.dart';
import '../../../../engine/color/curve.dart';
import '../../../../engine/color/curve_lut_baker.dart';
import '../../../../engine/pipeline/edit_pipeline.dart';
import '../../../../engine/pipeline/matrix_composer.dart';
import '../../../../engine/pipeline/tone_curve_set.dart';
import '../../../../engine/presets/lut_asset_cache.dart';
import '../../../../engine/rendering/shader_pass.dart';
import 'pass_builders.dart';

final _log = AppLogger('RenderDriver');

/// Builds the `List<ShaderPass>` the preview controller consumes, and
/// owns every piece of render-path state that lives longer than one
/// pass: the cached tone-curve LUT, the single-slot pending-bake
/// queue, the coalescing race guard, the reusable matrix scratch
/// buffer. Extracted from `editor_session.dart` in Phase VII.3 — the
/// session used to inline `_passesFor` + `_bakeCurveLut` +
/// `_startCurveBake` + the four private fields (`_curveLutKey`,
/// `_curveLutImage`, `_curveLutLoading`, `_pendingCurveBake`) +
/// `GenerationGuard<String>` + `Float32List(20)` + `CurveLutBaker`.
/// Lifting them here keeps session focused on pipeline orchestration
/// and makes the render-path invariants (coalescing, race guards,
/// zero-alloc matrix composition) independently testable.
///
/// Lifecycle mirrors the pre-VII.3 inline logic exactly:
///   * [passesFor] threads the driver's state into every builder via
///     `PassBuildContext`. Empty pipeline short-circuits to `const []`.
///   * [bakeCurveLut] either starts a bake immediately or stashes the
///     new request in the single-slot pending queue if one is already
///     in flight. On completion the driver drains the pending slot
///     (once), so a sustained drag at 60 Hz collapses to ≤ 2 isolate
///     spawns.
///   * [clearCurveLutCache] disposes the cached image + key when the
///     tone-curve op drops out of the pipeline.
///   * [dispose] releases the cached image + clears the gen guard +
///     flips `_disposed` so in-flight bakes drop their results.
class RenderDriver {
  RenderDriver({
    required this.onRebuildPreview,
    required this.isSessionDisposed,
  });

  /// Triggered after async resources (tone-curve LUT, 3D LUT asset)
  /// land so the canvas can pick them up on the next frame. Wired to
  /// `EditorSession.rebuildPreview` in production; tests pass a plain
  /// counter closure.
  final VoidCallback onRebuildPreview;

  /// Session-scoped disposal check. Bake completions ignore late
  /// arrivals once the session is gone, avoiding a write to a
  /// torn-down preview controller.
  final bool Function() isSessionDisposed;

  /// The matrix composer is stateless apart from its two static
  /// scratches — safe to share a const instance across sessions.
  static const MatrixComposer _composer = MatrixComposer();

  /// Phase VI.2: reusable 20-element buffer for the color-grading
  /// pass. [MatrixComposer.composeInto] writes into this every call
  /// to [passesFor] so sustained slider drag allocates zero per-frame
  /// matrices. Safe to reuse because the produced `ShaderPass` reads
  /// the buffer during the same frame's paint, before the next
  /// `passesFor` overwrites it (Flutter's single-threaded paint
  /// model).
  final Float32List _matrixScratch = Float32List(20);

  /// Baked 256×4 RGBA tone-curve LUT texture. Populated on demand
  /// the first time a curve op arrives, invalidated when the op
  /// drops out ([clearCurveLutCache]) or when the curve shape
  /// changes ([_curveLutKey] mismatch + restart bake).
  ui.Image? _curveLutImage;
  String? _curveLutKey;
  bool _curveLutLoading = false;
  static const CurveLutBaker _curveBaker = CurveLutBaker();

  /// Phase IV.4 per-key async-commit guard. Every bake stamps the
  /// `_curveBakeSlot` — the async finisher drops its result when a
  /// newer bake has taken the slot during the compute roundtrip.
  final GenerationGuard<String> _curveBakeGen = GenerationGuard<String>();
  static const String _curveBakeSlot = 'curve';

  /// Phase V.6 single-slot pending bake. Under sustained curve drag
  /// [bakeCurveLut] is called per frame (60 Hz) — without coalescing
  /// each call would spawn a fresh `compute()` isolate (~5–10 ms
  /// setup, worse than the 0.5 ms of Hermite math it was meant to
  /// offload). The in-flight bake runs to completion and any "newer
  /// curve while busy" request parks here; the completion handler
  /// drains it. Net: **≤ 1 isolate spawn per gesture** regardless of
  /// drag length.
  _PendingCurveBake? _pendingCurveBake;

  bool _disposed = false;

  /// XVI.33 — subject mask for the protect-aware vignette pass. When
  /// non-null this is the latest bg-removal cutout (its alpha is the
  /// subject mask). The render driver does not own the image — it is
  /// the AI coordinator's cutout, lifetime-bound to the originating
  /// layer. Setting this to null on bg-removal removal is the AI
  /// coordinator's responsibility.
  ui.Image? _subjectMaskImage;

  /// XVI.33 — 1×1 transparent fallback. Bound to the vignette pass's
  /// second sampler when no real subject mask exists, so the shader
  /// always has a valid texture even before the user has run bg
  /// removal. Lazily initialised on first read; disposed in [dispose].
  ui.Image? _subjectMaskFallback;
  Future<ui.Image>? _subjectMaskFallbackBake;

  /// XVI.40 — cached depth map for the lens-blur shader. Set by the
  /// AI coordinator when [DepthEstimator] finishes a run; cleared
  /// when the user picks a new source. The render driver does not
  /// own this image — the coordinator (matching the subject-mask
  /// pattern) owns its lifetime.
  ui.Image? _depthMapImage;

  /// Phase V.6 test-observable counter: how many times
  /// `CurveLutBaker.bakeInIsolate` was actually invoked. Tests
  /// simulate a 60-request drag burst and assert this stays at ≤ 2
  /// (one in-flight + one coalesced final).
  @visibleForTesting
  int get debugCurveBakeIsolateLaunches => _debugCurveBakeIsolateLaunches;
  int _debugCurveBakeIsolateLaunches = 0;

  /// Internal state accessors used by tests to pin the coalescing
  /// invariant without exposing the fields publicly.
  @visibleForTesting
  bool get debugHasPendingBake => _pendingCurveBake != null;
  @visibleForTesting
  bool get debugCurveLutLoading => _curveLutLoading;
  @visibleForTesting
  String? get debugCurveLutKey => _curveLutKey;
  @visibleForTesting
  ui.Image? get debugCurveLutImage => _curveLutImage;
  @visibleForTesting
  bool get debugDisposed => _disposed;

  /// Build the shader-pass list for [pipeline]. Empty pipeline
  /// short-circuits to `const []` so the single-empty-list identity
  /// flows through `previewController.setPasses` cleanly.
  List<ShaderPass> passesFor(EditPipeline pipeline) {
    if (pipeline.operations.isEmpty) return const [];
    final ctx = PassBuildContext(
      composer: _composer,
      matrixScratch: _matrixScratch,
      curveLutImage: _curveLutImage,
      curveLutKey: _curveLutKey,
      curveLutLoading: _curveLutLoading,
      onBakeCurveLut: bakeCurveLut,
      lutCache: LutAssetCache.instance,
      onRebuildPreview: onRebuildPreview,
      isDisposed: isSessionDisposed,
      onClearCurveLutCache: clearCurveLutCache,
      subjectMaskImage: _subjectMaskImage,
      subjectMaskFallback: _subjectMaskFallback,
      ensureSubjectMaskFallback: _ensureSubjectMaskFallback,
      depthMapImage: _depthMapImage,
    );
    final passes = <ShaderPass>[];
    for (final build in editorPassBuilders) {
      passes.addAll(build(pipeline, ctx));
    }
    return passes;
  }

  /// XVI.33 — Set (or clear) the cached bg-removal cutout image used
  /// by subject-aware ops (vignette today, future relighting / lens-
  /// blur tomorrow). Pass null to clear. Caller (AI coordinator) owns
  /// the image lifetime — the render driver only holds a reference.
  void setSubjectMaskImage(ui.Image? image) {
    if (_disposed) return;
    if (identical(_subjectMaskImage, image)) return;
    _subjectMaskImage = image;
    onRebuildPreview();
  }

  /// XVI.40 — Set (or clear) the cached depth map. The lens-blur pass
  /// reads this from [PassBuildContext] every render; clearing it (by
  /// passing null) drops the lens-blur pass from the chain on the next
  /// frame. Caller (AI coordinator) owns the image lifetime.
  void setDepthMapImage(ui.Image? image) {
    if (_disposed) return;
    if (identical(_depthMapImage, image)) return;
    _depthMapImage = image;
    onRebuildPreview();
  }

  @visibleForTesting
  ui.Image? get debugDepthMapImage => _depthMapImage;

  /// XVI.33 — Lazily produce the 1×1 transparent fallback subject
  /// mask. Returns null while the bake is in flight; the pass builder
  /// drops the protect (vignette renders without subject protection)
  /// for that one frame and picks up the bound fallback on the next
  /// rebuild. Idempotent — at most one bake outstanding per session.
  ui.Image? _ensureSubjectMaskFallback() {
    if (_disposed) return null;
    if (_subjectMaskFallback != null) return _subjectMaskFallback;
    if (_subjectMaskFallbackBake != null) return null;
    final completer = Completer<ui.Image>();
    final bake = completer.future;
    _subjectMaskFallbackBake = bake;
    // 1×1 RGBA = (0, 0, 0, 0) — fully transparent so `texture(...).a`
    // returns 0 → mask*protectStrength == 0 → vignette unchanged.
    final transparentBytes = Uint8List.fromList(const [0, 0, 0, 0]);
    ui.decodeImageFromPixels(
      transparentBytes,
      1,
      1,
      ui.PixelFormat.rgba8888,
      completer.complete,
    );
    unawaited(bake.then((image) {
      if (_disposed || isSessionDisposed()) {
        image.dispose();
        return;
      }
      _subjectMaskFallback = image;
      _subjectMaskFallbackBake = null;
      onRebuildPreview();
    }));
    return null;
  }

  /// Kick off (or coalesce) a tone-curve LUT bake for [set], keyed
  /// under [key]. [onRebuildPreview] fires when the bake lands so
  /// the next paint picks up the new LUT.
  void bakeCurveLut(String key, ToneCurveSet set) {
    if (_disposed) return;
    if (_curveLutLoading) {
      // In-flight bake already owns the isolate. Stash the newer
      // request — the completion handler drains it after the current
      // bake lands.
      _pendingCurveBake = _PendingCurveBake(key, set);
      return;
    }
    _startCurveBake(key, set);
  }

  void _startCurveBake(String key, ToneCurveSet set) {
    _curveLutLoading = true;
    _curveLutKey = key;
    _debugCurveBakeIsolateLaunches++;
    final stamp = _curveBakeGen.begin(_curveBakeSlot);
    ToneCurve? toCurve(List<List<double>>? pts) => pts == null
        ? null
        : ToneCurve([for (final p in pts) CurvePoint(p[0], p[1])]);
    unawaited(_curveBaker
        .bakeInIsolate(
      master: toCurve(set.master),
      red: toCurve(set.red),
      green: toCurve(set.green),
      blue: toCurve(set.blue),
      luma: toCurve(set.luma), // XVI.24
    )
        .then((image) {
      if (_disposed || isSessionDisposed()) {
        image.dispose();
        return;
      }
      // If a newer bake claimed the slot while we were off on an
      // async boundary, drop this result — `_curveLutKey` already
      // moved on and overwriting `_curveLutImage` would show the
      // wrong LUT until the newer bake lands.
      if (!_curveBakeGen.isLatest(_curveBakeSlot, stamp)) {
        image.dispose();
        return;
      }
      _curveLutImage?.dispose();
      _curveLutImage = image;
      _curveLutLoading = false;
      _log.d('curve lut baked', {'key': key});

      // Drain any bake request that arrived while we were busy.
      // Only the LATEST queued request survives (single slot), so
      // this is at worst one extra spawn per drag.
      final pending = _pendingCurveBake;
      _pendingCurveBake = null;
      if (pending != null && pending.key != key && !_disposed) {
        _startCurveBake(pending.key, pending.set);
        return;
      }
      onRebuildPreview();
    }, onError: (Object e, StackTrace st) {
      _log.e('curve lut bake failed', error: e, stackTrace: st);
      _curveLutLoading = false;
      // Still try to drain a pending request — the failure might
      // have been transient (e.g. isolate startup hiccup).
      final pending = _pendingCurveBake;
      _pendingCurveBake = null;
      if (pending != null && !_disposed) {
        _startCurveBake(pending.key, pending.set);
      }
    }));
  }

  /// Release the cached tone-curve LUT image. Called by the tone-
  /// curve pass builder when `pipeline.toneCurves` is null but the
  /// driver still holds a cached image (e.g. after the user cleared
  /// a curve).
  void clearCurveLutCache() {
    _curveLutImage?.dispose();
    _curveLutImage = null;
    _curveLutKey = null;
  }

  /// Free the cached LUT + halt any in-flight bake's result handling.
  /// Idempotent — safe to call twice.
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _curveLutImage?.dispose();
    _curveLutImage = null;
    _curveLutKey = null;
    _pendingCurveBake = null;
    _curveBakeGen.clear();
    // XVI.33 — fallback is owned by the driver; the actual subject
    // mask (`_subjectMaskImage`) is owned by the AI coordinator and
    // disposed there.
    _subjectMaskFallback?.dispose();
    _subjectMaskFallback = null;
    _subjectMaskImage = null;
  }
}

/// Phase V.6: single-slot pending bake request. When a tone-curve
/// bake is in flight and a newer curve arrives, the newer one sits
/// here until the in-flight bake completes. Only the latest wins —
/// a burst of 60 requests during a drag collapses to two isolate
/// spawns at most (one in-flight + one queued).
class _PendingCurveBake {
  const _PendingCurveBake(this.key, this.set);
  final String key;
  final ToneCurveSet set;
}
