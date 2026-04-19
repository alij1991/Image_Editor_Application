import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import '../../../core/logging/app_logger.dart';
import '../../../engine/pipeline/edit_op_type.dart';
import '../../../engine/pipeline/edit_pipeline.dart';
import '../../../engine/pipeline/matrix_composer.dart';
import '../../../engine/presets/preset.dart';

final _log = AppLogger('PresetThumbs');

/// Derived visual characterisation of a preset as applied to the
/// current photo. Held by the preset strip so each tile can render a
/// real preview of what the preset does instead of a hashed gradient.
///
/// We intentionally keep this cheap — we approximate each preset by
/// folding its matrix-composable ops (exposure, contrast, saturation,
/// hue, brightness) plus a linear-RGB approximation of temperature
/// and tint into a single 5×4 color matrix. Flutter can then render
/// the user's source image through that matrix via
/// `ColorFiltered(ColorFilter.matrix(...))`, which is one compositor
/// pass on any modern device.
///
/// What we **don't** approximate at thumbnail scale:
///   - vignette (rendered as a separate `RadialGradient` overlay)
///   - grain, clarity, dehaze, highlights/shadows/whites/blacks,
///     vibrance, split-toning
///
/// These effects require dedicated shader passes that don't fold into
/// a matrix. Re-rendering each tile through the full shader chain
/// would give pixel-accurate thumbnails but costs 3–5 FBOs per preset
/// per source change, which is wasteful for a preview strip. The
/// approximation below captures the *dominant* colour character of
/// every preset in the built-in set (B&W / warm / cool / faded /
/// saturated) — which is what users actually scan the strip for.
class PresetThumbnailRecipe {
  const PresetThumbnailRecipe({
    required this.colorMatrix,
    required this.vignetteAmount,
  });

  /// 20-element row-major 5×4 matrix to pass to
  /// `ColorFilter.matrix(...)`. Never null — always a well-formed
  /// matrix (identity for the Original preset).
  final Float32List colorMatrix;

  /// 0.0 – 1.0 strength of the vignette overlay. 0 = no vignette.
  final double vignetteAmount;

  bool get hasVignette => vignetteAmount > 0.02;
}

/// Compiles preset definitions into cheap-to-render
/// [PresetThumbnailRecipe]s and caches them per source-image
/// generation. The strip calls [recipeFor] on every tile; repeated
/// calls with the same preset id after the same generation are O(1).
class PresetThumbnailCache {
  PresetThumbnailCache();

  final Map<String, PresetThumbnailRecipe> _cache = {};
  int _generation = 0;

  /// Invalidate every cached recipe. Call when the source photo
  /// changes (new session, crop, rotate) so tiles recompute against
  /// the new pixels.
  void bumpGeneration() {
    _generation++;
    _cache.clear();
    _log.d('generation bumped', {'gen': _generation});
  }

  int get generation => _generation;

  /// Return the render recipe for [preset]. Cached per generation.
  PresetThumbnailRecipe recipeFor(Preset preset) {
    final cached = _cache[preset.id];
    if (cached != null) return cached;
    final built = _build(preset);
    _cache[preset.id] = built;
    return built;
  }

  PresetThumbnailRecipe _build(Preset preset) {
    // Build an EditPipeline fragment so MatrixComposer can fold the
    // matrix-composable ops for us (exposure, contrast, saturation,
    // hue, brightness, channelMixer). Non-matrix ops are skipped here
    // and handled by the supplementary logic below.
    var pipeline = EditPipeline.forOriginal('__thumb__');
    for (final op in preset.operations) {
      if (op.isMatrixComposable) {
        pipeline = pipeline.append(op);
      }
    }
    const composer = MatrixComposer();
    var matrix = composer.compose(pipeline);

    // Temperature / tint — approximate as linear RGB channel multipliers
    // on top of the composed matrix. Values roughly match what the
    // `color_grading.frag` shader does for small deltas (we're only
    // showing a 128 px preview so perfect parity isn't needed).
    double temp = 0, tint = 0;
    double vignetteAmount = 0;
    for (final op in preset.operations) {
      switch (op.type) {
        case EditOpType.temperature:
          temp += op.doubleParam('value');
          break;
        case EditOpType.tint:
          tint += op.doubleParam('value');
          break;
        case EditOpType.vignette:
          vignetteAmount =
              op.doubleParam('amount').clamp(0.0, 1.0).toDouble();
          break;
      }
    }
    if (temp != 0 || tint != 0) {
      matrix = _composeScaling(
        matrix: matrix,
        // Warm (+temp) boosts R, cuts B; cool does the inverse. The
        // 0.35 scale factor keeps the effect perceptually close to the
        // full shader at thumbnail size.
        rScale: 1 + temp * 0.35,
        gScale: 1 + tint * 0.20,
        bScale: 1 - temp * 0.35 - tint * 0.20,
      );
    }

    return PresetThumbnailRecipe(
      colorMatrix: matrix,
      vignetteAmount: vignetteAmount,
    );
  }

  /// Post-multiply the 5×4 [matrix] by an RGB channel-scaling matrix.
  /// Used to fold temperature/tint into the composer output without
  /// going through the full MatrixComposer machinery (which would
  /// require fabricating fake EditOperations for a non-matrix type).
  Float32List _composeScaling({
    required Float32List matrix,
    required double rScale,
    required double gScale,
    required double bScale,
  }) {
    final scaling = Float32List(20);
    scaling[0] = rScale;
    scaling[6] = gScale;
    scaling[12] = bScale;
    scaling[18] = 1.0;
    return MatrixComposer.multiply(scaling, matrix);
  }
}

/// Scale [source] to a 128 px long-edge [ui.Image]. Call once per
/// source change and share the result across every tile. The caller
/// owns the returned image and must `dispose()` it when finished.
Future<ui.Image> buildThumbnailProxy(ui.Image source) async {
  const targetLongEdge = 128;
  final w = source.width;
  final h = source.height;
  final longEdge = w > h ? w : h;
  if (longEdge <= targetLongEdge) {
    // Already small enough — clone via toByteData so the caller can
    // own the result and dispose independently of the caller's source.
    return _cloneImage(source);
  }
  final scale = targetLongEdge / longEdge;
  final outW = (w * scale).round();
  final outH = (h * scale).round();
  final recorder = ui.PictureRecorder();
  final canvas = ui.Canvas(recorder);
  final src = ui.Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble());
  final dst = ui.Rect.fromLTWH(0, 0, outW.toDouble(), outH.toDouble());
  final paint = ui.Paint()..filterQuality = ui.FilterQuality.medium;
  canvas.drawImageRect(source, src, dst, paint);
  final picture = recorder.endRecording();
  final img = await picture.toImage(outW, outH);
  picture.dispose();
  return img;
}

Future<ui.Image> _cloneImage(ui.Image source) async {
  final bytes = await source.toByteData(format: ui.ImageByteFormat.rawRgba);
  if (bytes == null) return source;
  final completer = Completer<ui.Image>();
  ui.decodeImageFromPixels(
    bytes.buffer.asUint8List(),
    source.width,
    source.height,
    ui.PixelFormat.rgba8888,
    completer.complete,
  );
  return completer.future;
}
