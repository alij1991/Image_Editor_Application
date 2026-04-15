import 'dart:ui' as ui;

import 'package:flutter/widgets.dart' show CustomPainter;

import 'shader_pass.dart';
import 'shader_registry.dart';

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
class ShaderRenderer extends CustomPainter {
  ShaderRenderer({
    required this.source,
    required this.passes,
    super.repaint,
  });

  /// The source image — normally the preview proxy (downscaled original).
  final ui.Image source;

  /// The chain of shader passes to apply. Empty list = draw source as-is.
  final List<ShaderPass> passes;

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

    ui.Image intermediate = source;
    bool sourceIsIntermediate = true; // don't dispose the caller-owned source
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
        if (!sourceIsIntermediate) intermediate.dispose();
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
        if (!sourceIsIntermediate) intermediate.dispose();
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

      if (!sourceIsIntermediate) intermediate.dispose();
      intermediate = next;
      sourceIsIntermediate = false;
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
    if (oldDelegate.source != source) return true;
    if (oldDelegate.passes.length != passes.length) return true;
    for (int i = 0; i < passes.length; i++) {
      if (oldDelegate.passes[i].assetKey != passes[i].assetKey) return true;
    }
    return true; // uniform changes are opaque to us; always repaint
  }
}
