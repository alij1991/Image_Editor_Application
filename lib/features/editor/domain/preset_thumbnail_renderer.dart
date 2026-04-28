import 'dart:typed_data';
import 'dart:ui' as ui;

import '../../../core/logging/app_logger.dart';
import '../../../engine/color/curve.dart';
import '../../../engine/color/curve_lut_baker.dart';
import '../../../engine/pipeline/edit_op_type.dart';
import '../../../engine/pipeline/edit_pipeline.dart';
import '../../../engine/pipeline/matrix_composer.dart';
import '../../../engine/pipeline/pipeline_extensions.dart';
import '../../../engine/presets/lut_asset_cache.dart';
import '../../../engine/presets/preset.dart';
import '../../../engine/rendering/shader_pass.dart';
import '../../../engine/rendering/shader_registry.dart';
import '../../../engine/rendering/shader_renderer.dart';
import '../presentation/notifiers/pass_builders.dart';

final _log = AppLogger('PresetThumbRender');

/// XVI.59 — non-matrix-foldable preset op types that force the
/// thumbnail to render through the full shader chain. Color-only
/// presets stay on the cheap matrix-recipe path.
///
/// `vignette` is in the list even though the matrix-recipe code
/// approximates it via a radial gradient overlay; the real shader
/// honours feather / roundness / centre offset which the gradient
/// can't, and the audit explicitly calls it out.
const Set<String> _realRenderTriggers = {
  EditOpType.toneCurve,
  EditOpType.grain,
  EditOpType.vignette,
  EditOpType.lut3d,
};

/// True when [preset] contains any op that the matrix-only recipe
/// can't faithfully represent. Color-only presets (brightness,
/// contrast, saturation, hue, exposure, temperature, tint) return
/// false.
bool presetNeedsRealRender(Preset preset) {
  for (final op in preset.operations) {
    if (_realRenderTriggers.contains(op.type)) return true;
  }
  return false;
}

/// Render [preset] applied to [source] into a square `ui.Image` of
/// side [targetSize] (default 96 px).
///
/// Returns null when the renderer can't produce a complete result —
/// shader failed to compile, all required passes returned empty,
/// 3D-LUT asset still loading. Callers fall back to the matrix
/// recipe path in those cases (silent fallback per project
/// convention).
///
/// **Synchronous resources** the function waits on:
///   * Every shader asset referenced by the resulting passes —
///     `ShaderRegistry.load()` is awaited so `ShaderRenderer.paint`
///     never short-circuits to "draw source unchanged".
///   * Tone-curve LUT (256×4 RGBA) — baked inline with
///     `CurveLutBaker.bake` (synchronous Hermite eval; the only
///     async step is `ui.decodeImageFromPixels`).
///   * 3D-LUT asset — `LutAssetCache.load(path)` is awaited per
///     referenced asset before passes are built.
Future<ui.Image?> renderPresetThumbnail({
  required ui.Image source,
  required Preset preset,
  int targetSize = 96,
}) async {
  // Build a minimal pipeline from the preset operations. Disabled
  // ops survive the round-trip (presets persist `enabled: true`
  // by construction; this guard is belt-and-suspenders).
  var pipeline = EditPipeline.forOriginal('__thumb__');
  for (final op in preset.operations) {
    if (!op.enabled) continue;
    pipeline = pipeline.append(op);
  }

  // ---- Pre-bake the tone-curve LUT (if any) ---------------------
  ui.Image? curveLut;
  String? curveLutKey;
  final curveSet = pipeline.toneCurves;
  if (curveSet != null) {
    curveLutKey = curveSet.cacheKey;
    try {
      curveLut = await const CurveLutBaker().bake(
        master: _toCurve(curveSet.master),
        red: _toCurve(curveSet.red),
        green: _toCurve(curveSet.green),
        blue: _toCurve(curveSet.blue),
        luma: _toCurve(curveSet.luma),
      );
    } catch (e, st) {
      _log.w('curve LUT bake failed', {'err': '$e', 'st': '$st'});
      // Drop the curve and continue — better to render the rest
      // of the chain than abort the whole thumbnail.
      curveLut = null;
      curveLutKey = null;
    }
  }

  // ---- Pre-load 3D LUT assets the preset references ------------
  // The lut3d pass builder no-ops on a cache miss; if we don't
  // pre-load every referenced asset the resulting pass list will
  // silently drop the lut3d effect for the first ~1-frame.
  for (final op in pipeline.operations) {
    if (op.type != EditOpType.lut3d) continue;
    final path = op.parameters['assetPath'] as String?;
    if (path == null) continue;
    if (LutAssetCache.instance.getCached(path) != null) continue;
    try {
      await LutAssetCache.instance.load(path);
    } catch (e) {
      _log.w('3D LUT preload failed', {'path': path, 'err': '$e'});
    }
  }

  // ---- Build the pass list -------------------------------------
  final ctx = PassBuildContext(
    composer: const MatrixComposer(),
    matrixScratch: Float32List(20),
    curveLutImage: curveLut,
    curveLutKey: curveLutKey,
    curveLutLoading: false,
    // The pre-bake above already populated `curveLut`. The pass
    // builder only invokes `onBakeCurveLut` on cache miss, so this
    // callback should be unreachable; pin it to a no-op rather
    // than a `throw` to keep the path strictly degrade-on-failure.
    onBakeCurveLut: (_, _) {},
    lutCache: LutAssetCache.instance,
    onRebuildPreview: () {},
    isDisposed: () => false,
    onClearCurveLutCache: () {},
  );
  final passes = <ShaderPass>[];
  for (final builder in editorPassBuilders) {
    passes.addAll(builder(pipeline, ctx));
  }
  if (passes.isEmpty) {
    curveLut?.dispose();
    return null;
  }

  // ---- Pre-load every shader the chain references --------------
  for (final pass in passes) {
    if (ShaderRegistry.instance.getCached(pass.assetKey) != null) continue;
    try {
      await ShaderRegistry.instance.load(pass.assetKey);
    } catch (e, st) {
      _log.w('shader load failed', {
        'asset': pass.assetKey,
        'err': '$e',
        'st': '$st',
      });
      curveLut?.dispose();
      return null;
    }
  }

  // ---- Render --------------------------------------------------
  final recorder = ui.PictureRecorder();
  final canvas = ui.Canvas(recorder);
  final size = ui.Size(targetSize.toDouble(), targetSize.toDouble());
  ShaderRenderer(source: source, passes: passes).paint(canvas, size);
  final picture = recorder.endRecording();
  ui.Image rendered;
  try {
    rendered = await picture.toImage(targetSize, targetSize);
  } catch (e, st) {
    _log.w('thumbnail toImage failed',
        {'preset': preset.id, 'err': '$e', 'st': '$st'});
    picture.dispose();
    curveLut?.dispose();
    return null;
  }
  picture.dispose();
  // Curve LUT is owned by us; the shader has already sampled from
  // it during paint and the resulting `ui.Image` is independent.
  curveLut?.dispose();
  return rendered;
}

ToneCurve? _toCurve(List<List<double>>? pts) {
  if (pts == null) return null;
  return ToneCurve([for (final p in pts) CurvePoint(p[0], p[1])]);
}
