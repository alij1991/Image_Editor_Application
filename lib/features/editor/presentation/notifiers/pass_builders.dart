import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import '../../../../engine/geometry/guided_upright.dart';
import '../../../../engine/pipeline/edit_op_type.dart';
import '../../../../engine/pipeline/edit_pipeline.dart';
import '../../../../engine/pipeline/matrix_composer.dart';
import '../../../../engine/pipeline/op_registry.dart';
import '../../../../engine/pipeline/pipeline_extensions.dart';
import '../../../../engine/pipeline/tone_curve_set.dart';
import '../../../../engine/presets/lut_asset_cache.dart';
import '../../../../engine/rendering/shader_pass.dart';
import '../../../../engine/rendering/shaders/color_grading_shader.dart';
import '../../../../engine/rendering/shaders/effect_shaders.dart';
import '../../../../engine/rendering/shaders/tonal_shaders.dart';

/// Signature every pass-builder shares. A builder takes the pipeline +
/// a small context bag of session state and returns 0 or more passes.
///
/// Returning `const []` is the canonical "no-op" path when the op
/// isn't enabled or the builder is waiting on an async resource
/// (e.g. tone-curve LUT still baking, 3D-LUT asset still loading).
typedef PassBuilder = List<ShaderPass> Function(
  EditPipeline pipeline,
  PassBuildContext ctx,
);

/// Context threaded into every pass builder. Carries pointers at
/// session state that async / stateful passes (tone curves, 3D LUT)
/// need to read and mutate. Pure pipeline-only builders ignore this
/// bag entirely.
///
/// Split out from the session itself so [editorPassBuilders] is
/// testable without a live `EditorSession` — the ordering test in
/// `test/engine/rendering/passes_for_test.dart` drives the list with
/// a minimal stub context.
class PassBuildContext {
  const PassBuildContext({
    required this.composer,
    required this.matrixScratch,
    required this.curveLutImage,
    required this.curveLutKey,
    required this.curveLutLoading,
    required this.onBakeCurveLut,
    required this.lutCache,
    required this.onRebuildPreview,
    required this.isDisposed,
    required this.onClearCurveLutCache,
    this.subjectMaskImage,
    this.subjectMaskFallback,
    this.ensureSubjectMaskFallback,
  });

  /// Matrix composer reused across sessions — folds all
  /// matrix-composable color ops into a single 5x4 matrix.
  final MatrixComposer composer;

  /// Phase VI.2: session-owned reusable 20-element [Float32List] for
  /// the color-grading pass's composed matrix. Passed into
  /// [MatrixComposer.composeInto] so the hot path under slider drag
  /// allocates zero per-frame buffers. The resulting [ShaderPass] only
  /// reads the buffer during paint (same frame as `_passesFor`), and
  /// the next frame's `_passesFor` overwrites it atomically — safe
  /// under Flutter's single-threaded paint model.
  final Float32List matrixScratch;

  /// Current cached tone-curve LUT (256×4 RGBA). Null when no curve
  /// is active or the bake hasn't landed yet.
  final ui.Image? curveLutImage;

  /// Cache key the cached [curveLutImage] was baked for. Used to
  /// detect a curve edit that invalidates the cached image.
  final String? curveLutKey;

  /// True while a tone-curve LUT bake is in flight. Prevents
  /// spawning a second bake for the same key.
  final bool curveLutLoading;

  /// Kick off an async tone-curve LUT bake. Session re-renders when
  /// the bake lands.
  final void Function(String key, ToneCurveSet set) onBakeCurveLut;

  /// Shared LUT-asset cache (PNG LUTs on disk → `ui.Image`).
  final LutAssetCache lutCache;

  /// Triggers a preview rebuild after an async resource lands.
  final void Function() onRebuildPreview;

  /// Session-scoped disposal check. Builders avoid scheduling
  /// rebuilds past the session's lifetime.
  final bool Function() isDisposed;

  /// Clear the cached tone-curve LUT image when no curve is active.
  /// Called from the tone-curve builder when `pipeline.toneCurves`
  /// is null but a cached image is still held.
  final void Function() onClearCurveLutCache;

  /// XVI.33 — latest bg-removal cutout (alpha = subject mask). Null
  /// when the user hasn't run bg-removal yet OR has dropped the
  /// resulting layer. Subject-aware passes (vignette today, lens
  /// blur / relighting tomorrow) read this; when null they degrade
  /// to "no protect" via [subjectMaskFallback].
  final ui.Image? subjectMaskImage;

  /// XVI.33 — 1×1 transparent fallback subject mask. Bound to a pass's
  /// sampler when [subjectMaskImage] is null so the shader always has
  /// a valid texture. Null on the first frame the protect-aware op
  /// activates (the fallback is being baked); pass builders skip the
  /// pass when both this and [subjectMaskImage] are null and the
  /// rebuild fires once the bake lands.
  final ui.Image? subjectMaskFallback;

  /// XVI.33 — kick off the lazy fallback bake (if not yet started).
  /// Returns the cached fallback when ready, null otherwise. Pass
  /// builders call this once per render to amortise the bake into the
  /// first frame the protect-aware op activates.
  final ui.Image? Function()? ensureSubjectMaskFallback;
}

/// Canonical render-chain order.
///
/// Reading this list top-to-bottom tells you what the renderer does
/// with any `EditPipeline`. Each builder returns 0 or more passes;
/// `_passesFor` (now a one-liner) concatenates them.
///
/// Phase 3 (rendering chain) splits into four bands:
///   1. **Global color grading** — matrix + exposure/temp/tint.
///   2. **Tone-local** — highlights-shadows, vibrance, dehaze,
///      levels+gamma, HSL, split-toning, curves, 3D LUT.
///   3. **Detail** — denoise, sharpen.
///   4. **Effects + blurs + FX** — tilt-shift, motion blur, vignette,
///      chromatic aberration, pixelate, halftone, glitch, grain.
///
/// Order within a band reflects the visual dependency chain (e.g.
/// highlights-shadows before vibrance because vibrance operates on
/// saturation and H/S/W/B changes the gamut first).
///
/// Inserting a new op means picking its correct position in this
/// list — not hunting through 300 lines of `if` branches. The
/// ordering test in `passes_for_test.dart` locks the sequence for
/// canonical pipelines.
final List<PassBuilder> editorPassBuilders = [
  // ---------- Geometry (projective) ----------
  // XVI.45 — Guided Upright runs FIRST in the chain so the rest of
  // the color/FX passes operate on the warped image. Affine geometry
  // (rotate/flip/straighten/crop) is still applied by the canvas
  // RenderBox via Transform/RotatedBox; only the projective pass
  // lives in the shader chain.
  _guidedUprightPass,
  // XVI.46 — Brown-Conrady radial distortion correction. Runs after
  // perspective correction (so the upright-warped image is then
  // de-distorted) and before any color grading. The pass is
  // typically auto-populated from EXIF on session start.
  _lensDistortionPass,
  // ---------- Global color grading ----------
  _colorGradingPass,
  // ---------- Tone-local ----------
  _highlightsShadowsPass,
  _vibrancePass,
  _clarityPass,
  _texturePass,
  _dehazePass,
  _levelsGammaPass,
  _hslPass,
  _splitToningPass,
  _colorGradingWheelsPass,
  _toneCurvePass,
  _lut3dPass,
  // ---------- Detail ----------
  _bilateralDenoisePass,
  _sharpenPass,
  // ---------- Effects + blurs + FX ----------
  _tiltShiftPass,
  _motionBlurPass,
  _vignettePass,
  _chromaticAberrationPass,
  _pixelatePass,
  _halftonePass,
  _glitchPass,
  _grainPass,
];

// =========================================================================
// Builders. Each returns an empty list when the op isn't active —
// callers use `list.addAll(builder(...))` to preserve order.
// =========================================================================

/// XVI.45 — Guided Upright perspective. The op carries a list of
/// user-drawn line quads; the solver derives a 3×3 source→dest
/// homography. The shader expects dest→source for inverse-warp
/// sampling, so we invert here. Identity / degenerate solves drop
/// the pass entirely so the chain stays short.
List<ShaderPass> _guidedUprightPass(EditPipeline p, PassBuildContext ctx) {
  final op = p.findOp(EditOpType.guidedUpright);
  if (op == null) return const [];
  final lines = GuidedUprightLineCodec.decode(op.parameters['lines']);
  if (lines.length < 2) return const [];
  final forward = GuidedUprightSolver.solve(lines);
  // Identity → no-op (cheap short-circuit before the inversion).
  if (_isIdentityHomography(forward)) return const [];
  final inverse = invert3x3(forward);
  if (inverse == null) return const [];
  return [PerspectiveWarpShader(homography: inverse).toPass()];
}

bool _isIdentityHomography(List<double> h) {
  for (var i = 0; i < 9; i++) {
    final expected = (i == 0 || i == 4 || i == 8) ? 1.0 : 0.0;
    if ((h[i] - expected).abs() > 1e-6) return false;
  }
  return true;
}

/// XVI.46 — Lens distortion correction. Skips the pass when both
/// coefficients are below the noise floor (1e-4) so the renderer
/// chain stays short for un-profiled cameras.
List<ShaderPass> _lensDistortionPass(EditPipeline p, PassBuildContext ctx) {
  final op = p.findOp(EditOpType.lensDistortion);
  if (op == null) return const [];
  final k1 = op.doubleParam('k1');
  final k2 = op.doubleParam('k2');
  if (k1.abs() < 1e-4 && k2.abs() < 1e-4) return const [];
  return [LensDistortionShader(k1: k1, k2: k2).toPass()];
}

List<ShaderPass> _colorGradingPass(EditPipeline p, PassBuildContext ctx) {
  // The composed matrix is zero-cost at identity, but we only add
  // the pass when at least one of its composed ops is present so the
  // chain stays short for untouched photos.
  final hasMatrixOp = p.operations.any(
    (o) => o.enabled && OpRegistry.matrixComposable.contains(o.type),
  );
  final hasTempTintExposure = p.hasEnabledOp(EditOpType.exposure) ||
      p.hasEnabledOp(EditOpType.temperature) ||
      p.hasEnabledOp(EditOpType.tint);
  if (!hasMatrixOp && !hasTempTintExposure) return const [];
  final matrix = ctx.composer.composeInto(p, ctx.matrixScratch);
  return [
    ColorGradingShader(
      colorMatrix5x4: matrix,
      exposure: p.exposureValue,
      temperature: p.temperatureValue,
      tint: p.tintValue,
    ).toPass(),
  ];
}

List<ShaderPass> _highlightsShadowsPass(EditPipeline p, PassBuildContext ctx) {
  final hasAny = p.hasEnabledOp(EditOpType.highlights) ||
      p.hasEnabledOp(EditOpType.shadows) ||
      p.hasEnabledOp(EditOpType.whites) ||
      p.hasEnabledOp(EditOpType.blacks);
  if (!hasAny) return const [];
  return [
    HighlightsShadowsShader(
      highlights: p.highlightsValue,
      shadows: p.shadowsValue,
      whites: p.whitesValue,
      blacks: p.blacksValue,
    ).toPass(),
  ];
}

List<ShaderPass> _vibrancePass(EditPipeline p, PassBuildContext ctx) {
  if (!p.hasEnabledOp(EditOpType.vibrance)) return const [];
  return [VibranceShader(vibrance: p.vibranceValue).toPass()];
}

// Phase XI.0.5: clarity now uses a self-contained shader (inline 9-tap
// Gaussian blur for the midtone unsharp mask). Placed after vibrance so
// the boost runs on already-graded chroma; before dehaze/LUT/detail so
// the midtone lift doesn't fight later atmospheric ops.
List<ShaderPass> _clarityPass(EditPipeline p, PassBuildContext ctx) {
  if (!p.hasEnabledOp(EditOpType.clarity)) return const [];
  return [ClarityShader(clarity: p.clarityValue).toPass()];
}

// Phase XVI.23: Texture is the fine-frequency sibling of clarity —
// runs immediately after so a positive Texture amount on top of a
// positive Clarity amount stacks micro-detail on top of midtone
// punch without the two unsharp masks doubling up at the same
// frequency band.
List<ShaderPass> _texturePass(EditPipeline p, PassBuildContext ctx) {
  if (!p.hasEnabledOp(EditOpType.texture)) return const [];
  return [TextureShader(amount: p.textureValue).toPass()];
}

List<ShaderPass> _dehazePass(EditPipeline p, PassBuildContext ctx) {
  if (!p.hasEnabledOp(EditOpType.dehaze)) return const [];
  return [DehazeShader(amount: p.dehazeValue).toPass()];
}

List<ShaderPass> _levelsGammaPass(EditPipeline p, PassBuildContext ctx) {
  // Phase XVI.22 — black, white, gamma all live on EditOpType.levels.
  // The dead `hasEnabledOp(EditOpType.gamma)` branch was a leftover
  // from the same typo that broke the gamma reader; no UI path ever
  // produced ops of type EditOpType.gamma so the OR was always false
  // when the levels op wasn't present anyway. The type registration
  // stays so the consistency tests + any persisted pipelines that
  // somehow carry it still load cleanly.
  if (!p.hasEnabledOp(EditOpType.levels)) return const [];
  return [
    LevelsGammaShader(
      black: p.levelsBlack,
      white: p.levelsWhite,
      gamma: p.levelsGamma,
    ).toPass(),
  ];
}

List<ShaderPass> _hslPass(EditPipeline p, PassBuildContext ctx) {
  if (!p.hasEnabledOp(EditOpType.hsl)) return const [];
  return [
    HslShader(
      hueDelta: p.hslHueDelta,
      satDelta: p.hslSatDelta,
      lumDelta: p.hslLumDelta,
    ).toPass(),
  ];
}

List<ShaderPass> _splitToningPass(EditPipeline p, PassBuildContext ctx) {
  if (!p.hasEnabledOp(EditOpType.splitToning)) return const [];
  return [
    SplitToningShader(
      highlightColor: p.splitHighlightColor,
      shadowColor: p.splitShadowColor,
      balance: p.splitBalance,
    ).toPass(),
  ];
}

/// Phase XVI.27 — three-wheel Color Grading. NB: the function name
/// uses "Wheels" to disambiguate from `_colorGradingPass` above (the
/// matrix-composer fan-in for the matrix-composable color ops).
List<ShaderPass> _colorGradingWheelsPass(
  EditPipeline p,
  PassBuildContext ctx,
) {
  if (!p.hasEnabledOp(EditOpType.colorGrading)) return const [];
  return [
    ColorGrading3WheelShader(
      shadowColor: p.colorGradingShadowColor,
      midColor: p.colorGradingMidColor,
      highColor: p.colorGradingHighColor,
      globalColor: p.colorGradingGlobalColor,
      balance: p.colorGradingBalance,
      blending: p.colorGradingBlending,
    ).toPass(),
  ];
}

List<ShaderPass> _toneCurvePass(EditPipeline p, PassBuildContext ctx) {
  // Bakes a 256×4 RGBA LUT lazily and caches it keyed by the points
  // list so authoring the same shape twice (or undo/redo through it)
  // hits the cache. The bake is async; we skip the pass on first
  // sight and `onRebuildPreview` when it lands — same pattern as the
  // 3D LUT path.
  final curveSet = p.toneCurves;
  if (curveSet != null) {
    final key = curveSet.cacheKey;
    if (ctx.curveLutImage != null && ctx.curveLutKey == key) {
      return [CurvesShader(curveLut: ctx.curveLutImage!).toPass()];
    } else if (!ctx.curveLutLoading || ctx.curveLutKey != key) {
      ctx.onBakeCurveLut(key, curveSet);
    }
    return const [];
  }
  // Curve cleared — drop the cached image so memory doesn't hang on
  // to it across the rest of the session.
  if (ctx.curveLutImage != null) {
    ctx.onClearCurveLutCache();
  }
  return const [];
}

List<ShaderPass> _lut3dPass(EditPipeline p, PassBuildContext ctx) {
  final passes = <ShaderPass>[];
  for (final op in p.operations) {
    if (!op.enabled || op.type != EditOpType.lut3d) continue;
    final assetPath = op.parameters['assetPath'] as String?;
    if (assetPath == null) continue;
    // Clamp to [0,1]: preset-amount extrapolation (Phase III.4) can
    // produce intensity=1.5 when amount=1.5 against a preset-literal
    // intensity of 1.0. The shader's mix(src, graded, intensity)
    // doesn't clamp internally, so we guard here rather than push
    // out-of-gamut values into the GPU.
    final intensity =
        ((op.parameters['intensity'] as num?)?.toDouble() ?? 1.0)
            .clamp(0.0, 1.0);
    final lut = ctx.lutCache.getCached(assetPath);
    if (lut == null) {
      // Trigger async load; skip this pass for now.
      unawaited(ctx.lutCache.load(assetPath).then((_) {
        if (!ctx.isDisposed()) ctx.onRebuildPreview();
      }));
      continue;
    }
    passes.add(Lut3dShader(lut: lut, intensity: intensity).toPass());
  }
  return passes;
}

List<ShaderPass> _bilateralDenoisePass(EditPipeline p, PassBuildContext ctx) {
  if (!p.hasEnabledOp(EditOpType.denoiseBilateral)) return const [];
  return [
    BilateralDenoiseShader(
      sigmaSpatial:
          p.readParam(EditOpType.denoiseBilateral, 'sigmaSpatial', 2),
      sigmaRange:
          p.readParam(EditOpType.denoiseBilateral, 'sigmaRange', 0.15),
      radius: p.readParam(EditOpType.denoiseBilateral, 'radius', 2),
    ).toPass(),
  ];
}

List<ShaderPass> _sharpenPass(EditPipeline p, PassBuildContext ctx) {
  if (!p.hasEnabledOp(EditOpType.sharpen)) return const [];
  return [
    SharpenUnsharpShader(
      amount: p.readParam(EditOpType.sharpen, 'amount'),
      radius: p.readParam(EditOpType.sharpen, 'radius', 1),
    ).toPass(),
  ];
}

List<ShaderPass> _tiltShiftPass(EditPipeline p, PassBuildContext ctx) {
  if (!p.hasEnabledOp(EditOpType.tiltShift)) return const [];
  return [
    TiltShiftShader(
      focusX: p.readParam(EditOpType.tiltShift, 'focusX', 0.5),
      focusY: p.readParam(EditOpType.tiltShift, 'focusY', 0.5),
      focusWidth: p.readParam(EditOpType.tiltShift, 'focusWidth', 0.15),
      blurAmount: p.readParam(EditOpType.tiltShift, 'blurAmount'),
      angle: p.readParam(EditOpType.tiltShift, 'angle'),
    ).toPass(),
  ];
}

List<ShaderPass> _motionBlurPass(EditPipeline p, PassBuildContext ctx) {
  if (!p.hasEnabledOp(EditOpType.motionBlur)) return const [];
  final angle = p.readParam(EditOpType.motionBlur, 'angle');
  return [
    MotionBlurShader(
      directionX: math.cos(angle),
      directionY: math.sin(angle),
      samples: 16,
      strength: p.readParam(EditOpType.motionBlur, 'strength'),
    ).toPass(),
  ];
}

List<ShaderPass> _vignettePass(EditPipeline p, PassBuildContext ctx) {
  if (!p.hasEnabledOp(EditOpType.vignette)) return const [];
  // XVI.33 — protect-aware vignette. The op may carry raw params
  // `protectSubject` / `protectStrength`; if not set, the protect
  // is identity (strength = 0) and the shader output equals the
  // pre-XVI.33 vignette.
  final op = p.findOp(EditOpType.vignette)!;
  final protectFlag = op.boolParam('protectSubject');
  final rawStrength = op.doubleParam('protectStrength', 0.5);
  final protectStrength =
      (protectFlag ? rawStrength : 0.0).clamp(0.0, 1.0);
  // Bind the cached subject mask when one exists, otherwise the
  // 1×1 transparent fallback. The fallback may be null on the very
  // first frame after enabling the protect (the lazy bake is in
  // flight); skip the pass entirely for that one frame and let the
  // bake's onRebuildPreview drive the next render.
  ui.Image? mask = ctx.subjectMaskImage;
  if (mask == null) {
    mask = ctx.subjectMaskFallback ??
        ctx.ensureSubjectMaskFallback?.call();
    if (mask == null) return const [];
  }
  return [
    VignetteShader(
      amount: p.readParam(EditOpType.vignette, 'amount'),
      feather: p.readParam(EditOpType.vignette, 'feather', 0.4),
      roundness: p.readParam(EditOpType.vignette, 'roundness', 0.5),
      centerX: p.readParam(EditOpType.vignette, 'centerX', 0.5),
      centerY: p.readParam(EditOpType.vignette, 'centerY', 0.5),
      subjectMask: mask,
      protectStrength: protectStrength,
    ).toPass(),
  ];
}

List<ShaderPass> _chromaticAberrationPass(
    EditPipeline p, PassBuildContext ctx) {
  if (!p.hasEnabledOp(EditOpType.chromaticAberration)) return const [];
  return [
    ChromaticAberrationShader(
      amount: p.readParam(EditOpType.chromaticAberration, 'amount'),
    ).toPass(),
  ];
}

List<ShaderPass> _pixelatePass(EditPipeline p, PassBuildContext ctx) {
  if (!p.hasEnabledOp(EditOpType.pixelate)) return const [];
  // Skip the pass at sub-visible pixel sizes — 1.0 is identity, the
  // UI slider rounds toward 1.5 before the effect kicks in.
  final px = p.readParam(EditOpType.pixelate, 'pixelSize', 1);
  if (px <= 1.5) return const [];
  return [PixelateShader(pixelSize: px).toPass()];
}

List<ShaderPass> _halftonePass(EditPipeline p, PassBuildContext ctx) {
  if (!p.hasEnabledOp(EditOpType.halftone)) return const [];
  return [
    HalftoneShader(
      dotSize: p.readParam(EditOpType.halftone, 'dotSize', 6),
      angle: p.readParam(EditOpType.halftone, 'angle', 0.785),
    ).toPass(),
  ];
}

List<ShaderPass> _glitchPass(EditPipeline p, PassBuildContext ctx) {
  if (!p.hasEnabledOp(EditOpType.glitch)) return const [];
  return [
    GlitchShader(
      amount: p.readParam(EditOpType.glitch, 'amount'),
      // Seeded by wall time so successive frames show different
      // displacements; modulo keeps the value bounded.
      time: DateTime.now().millisecondsSinceEpoch / 1000.0 % 100,
    ).toPass(),
  ];
}

List<ShaderPass> _grainPass(EditPipeline p, PassBuildContext ctx) {
  if (!p.hasEnabledOp(EditOpType.grain)) return const [];
  return [
    GrainShader(
      amount: p.readParam(EditOpType.grain, 'amount'),
      cellSize: p.readParam(EditOpType.grain, 'cellSize', 2),
      seed: 1,
      // XVI.34 — per-band amplitudes default to 1.0 so legacy ops
      // (which only carry `amount` + `cellSize`) render as uniform
      // grain across the luminance range, matching pre-XVI.34
      // behaviour exactly.
      shadows: p.readParam(EditOpType.grain, 'shadows', 1.0),
      mids: p.readParam(EditOpType.grain, 'mids', 1.0),
      highs: p.readParam(EditOpType.grain, 'highs', 1.0),
    ).toPass(),
  ];
}
