import 'dart:ui' as ui;

import 'package:flutter/widgets.dart' show CustomPainter;

import 'shader_pass.dart';
import 'shader_registry.dart';
import 'shader_texture_pool.dart';

/// [CustomPainter] that draws a source [ui.Image] through a chain of
/// fragment shader passes.
///
/// The shader chain is the hot path for real-time preview. Each pass
/// reads the previous pass's output as `u_texture` and the renderer
/// allocates an offscreen [ui.PictureRecorder] per intermediate result
/// to avoid re-uploading the source texture.
///
/// Performance notes (blueprint targets):
/// - Single pass @ 1080p: < 2 ms
/// - Full color chain (matrix + curves + LUT + H/S): < 5 ms
/// - The CustomPainter itself must *not* allocate any new shaders on the
///   paint path. All [ui.FragmentShader] instances are acquired from the
///   registry and reused; only uniform values change between frames.
///
/// ## Ping-pong texture pool (Phase VI.1)
///
/// When a [pool] is supplied (editor live-preview path), intermediate
/// `ui.Image`s are installed into the pool rather than managed via local
/// refs. The pool rotates between two slots so pass N+2 disposes pass
/// N's output (safe: pass N+2 reads pass N+1, which is in the opposite
/// slot). Across frames the pool keeps slots alive so Skia's GPU texture
/// cache retains the backing memory. Transient callers (export, before-
/// after compare) omit the pool — those paths are one-shot, so pooling
/// would only add lifetime hazard.
class ShaderRenderer extends CustomPainter {
  ShaderRenderer({
    required this.source,
    required this.passes,
    this.pool,
    super.repaint,
  });

  /// The source image — normally the preview proxy (downscaled original).
  final ui.Image source;

  /// The chain of shader passes to apply. Empty list = draw source as-is.
  final List<ShaderPass> passes;

  /// Optional ping-pong pool for intermediate images. When null, each
  /// non-final pass allocates and disposes its intermediate locally.
  final ShaderTexturePool? pool;

  @override
  void paint(ui.Canvas canvas, ui.Size size) {
    if (passes.isEmpty) {
      _drawImage(canvas, source, size);
      return;
    }

    // Intermediate passes rasterize at the SOURCE PROXY'S resolution,
    // not the widget's display size. Otherwise every chained shader
    // pass downsamples the image to ~360 logical px, and stacking 3-5
    // ops (any auto-fix preset) visibly softens the photo. The proxy
    // is already memory-budgeted upstream (`previewLongEdge`), so we
    // know this fits.
    final ui.Size intermediateSize = ui.Size(
      source.width.toDouble(),
      source.height.toDouble(),
    );

    final ShaderTexturePool? pool = this.pool;
    if (pool != null) {
      pool.beginFrame(width: source.width, height: source.height);
    }

    ui.Image intermediate = source;
    // `intermediate` points at either `source` (caller-owned, never
    // disposed by us) or a pool-owned ui.Image (lifetime managed by the
    // pool) or — when pool is null — a local intermediate we own.
    // `localIntermediate` is the only one we must dispose manually.
    ui.Image? localIntermediate;
    for (int i = 0; i < passes.length; i++) {
      final pass = passes[i];
      final isLast = i == passes.length - 1;
      final program = ShaderRegistry.instance.getCached(pass.assetKey);
      if (program == null) {
        // Shader hasn't been loaded yet. Just draw the last intermediate
        // and trigger a load in the background. On the next paint the
        // chain will include this pass.
        ShaderRegistry.instance.load(pass.assetKey);
        _drawImage(canvas, intermediate, size);
        localIntermediate?.dispose();
        return;
      }

      if (isLast) {
        // Final pass writes directly to the screen canvas at display
        // size — Flutter's compositor handles the up-scale to physical
        // pixels via the canvas' own transform, so this is HiDPI-clean.
        _applyPass(
          canvas: canvas,
          program: program,
          pass: pass,
          input: intermediate,
          size: size,
        );
        localIntermediate?.dispose();
        return;
      }

      // Record the pass result into an offscreen Picture, then rasterize
      // it to a new ui.Image (at source resolution) that the next pass
      // will sample.
      final recorder = ui.PictureRecorder();
      final offscreenCanvas = ui.Canvas(recorder);
      _applyPass(
        canvas: offscreenCanvas,
        program: program,
        pass: pass,
        input: intermediate,
        size: intermediateSize,
      );
      final picture = recorder.endRecording();
      final next = picture.toImageSync(
        intermediateSize.width.round(),
        intermediateSize.height.round(),
      );
      picture.dispose();

      if (pool != null) {
        // Pool takes ownership. It disposes the slot-peer (pass i-2's
        // output) which the next pass no longer reads. Our local
        // `intermediate` (== pass i-1's output, in the opposite slot)
        // is still alive in the pool.
        pool.install(next);
        intermediate = next;
        localIntermediate = null;
      } else {
        localIntermediate?.dispose();
        intermediate = next;
        localIntermediate = next;
      }
    }
  }

  void _applyPass({
    required ui.Canvas canvas,
    required ui.FragmentProgram program,
    required ShaderPass pass,
    required ui.Image input,
    required ui.Size size,
  }) {
    final shader = program.fragmentShader();
    // u_size at indices 0, 1 (vec2 is packed as two floats).
    shader.setFloat(0, size.width);
    shader.setFloat(1, size.height);
    // u_texture sampler at index 0.
    shader.setImageSampler(0, input);
    // Additional samplers starting at index 1.
    for (int i = 0; i < pass.samplers.length; i++) {
      shader.setImageSampler(i + 1, pass.samplers[i]);
    }
    // Op-specific uniforms start at float index 2 (after u_size).
    pass.setUniforms(shader, 2);

    final paint = ui.Paint()..shader = shader;
    canvas.drawRect(
      ui.Rect.fromLTWH(0, 0, size.width, size.height),
      paint,
    );
  }

  static void _drawImage(ui.Canvas canvas, ui.Image image, ui.Size size) {
    final paint = ui.Paint()..filterQuality = ui.FilterQuality.medium;
    canvas.drawImageRect(
      image,
      ui.Rect.fromLTWH(
        0,
        0,
        image.width.toDouble(),
        image.height.toDouble(),
      ),
      ui.Rect.fromLTWH(0, 0, size.width, size.height),
      paint,
    );
  }

  @override
  bool shouldRepaint(covariant ShaderRenderer oldDelegate) {
    if (!identical(oldDelegate.source, source)) return true;
    if (oldDelegate.passes.length != passes.length) return true;
    // Phase XI.A.3: compare uniform contentHash snapshots per pass.
    // When every pass on both sides carries a hash and every pair
    // matches, the frame is guaranteed structurally identical — skip
    // the repaint. Any null hash on either side falls back to the
    // conservative always-repaint path (matches pre-XI.A.3 behaviour).
    for (int i = 0; i < passes.length; i++) {
      final a = passes[i];
      final b = oldDelegate.passes[i];
      if (a.assetKey != b.assetKey) return true;
      if (a.contentHash == null || b.contentHash == null) return true;
      if (a.contentHash != b.contentHash) return true;
      if (a.intensity != b.intensity) return true;
      if (a.samplers.length != b.samplers.length) return true;
      for (int j = 0; j < a.samplers.length; j++) {
        if (!identical(a.samplers[j], b.samplers[j])) return true;
      }
    }
    return false;
  }
}
