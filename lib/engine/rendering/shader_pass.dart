import 'dart:typed_data';
import 'dart:ui' as ui;

/// A single GPU shader pass description. Consumed by [ShaderRenderer].
///
/// A pass represents "apply this fragment shader with these uniforms to
/// the current intermediate `ui.Image`". Passes are chained in order —
/// each one reads the previous output as `u_texture`.
class ShaderPass {
  const ShaderPass({
    required this.assetKey,
    required this.setUniforms,
    this.samplers = const [],
    this.intensity = 1.0,
    this.contentHash,
  });

  /// Asset key resolved via [ShaderRegistry].
  final String assetKey;

  /// Callback invoked to set all of the pass's non-sampler uniforms on a
  /// freshly acquired [ui.FragmentShader]. `u_size` is set automatically
  /// by the renderer before this callback runs (at uniform index 0/1).
  ///
  /// The first user-writable float index is passed in; implementations
  /// should return the NEXT free index after writing their uniforms so
  /// chained setters stay in sync. Most callers simply ignore the return
  /// value.
  final int Function(ui.FragmentShader shader, int firstIndex) setUniforms;

  /// Additional sampler inputs beyond `u_texture` (e.g. `u_curveLut`,
  /// `u_lut`, `u_blurred`). `u_texture` is set automatically by the
  /// renderer from the previous pass's output.
  final List<ui.Image> samplers;

  /// Per-pass blend factor. Used by presets to cross-fade between the
  /// input and the shader output (e.g. "preset at 50% intensity"). The
  /// renderer interprets intensity < 1 as "mix previous with current",
  /// which costs one extra shader invocation but is worth the
  /// convenience for filter strength sliders.
  final double intensity;

  /// Opaque stable hash of the pass's uniforms, snapshotted at
  /// [toPass]-time. Consumed by [ShaderRenderer.shouldRepaint] to
  /// skip GPU work when a frame is rebuilt with the same uniform
  /// values (e.g. ancestor widget bubble, global resize). Null means
  /// "treat as dirty" — the renderer falls back to its pre-Phase-XI.A.3
  /// always-repaint behaviour.
  ///
  /// Shaders with mutable-scratch inputs (e.g. `ColorGradingShader`'s
  /// reused 20-element [Float32List]) MUST snapshot the hash when
  /// [toPass] is called, not defer the computation — the buffer's
  /// contents get overwritten on the next frame, so comparing the
  /// current frame's buffer against itself would always report equal.
  final int? contentHash;

  /// Helper for passes that need to pack a 5x4 matrix into sequential
  /// float uniforms. Flutter's FragmentShader API only exposes setFloat,
  /// so matrices are uploaded as 16 (or 20) floats in row-major order.
  static int uploadMat4(
    ui.FragmentShader shader,
    int startIndex,
    Float32List mat,
  ) {
    for (int i = 0; i < 16 && i < mat.length; i++) {
      shader.setFloat(startIndex + i, mat[i]);
    }
    return startIndex + 16;
  }
}
