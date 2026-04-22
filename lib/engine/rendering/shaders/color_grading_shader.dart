import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';

import '../shader_keys.dart';
import '../shader_pass.dart';

/// Dart-side wrapper for `shaders/color_grading.frag`.
///
/// Uniform layout (GLSL -> Flutter setFloat indices):
///   0..1   u_size          (vec2)     set by ShaderRenderer
///   2..17  u_colorMatrix   (mat4)     16 floats, **column-major 4x4**
///   18..21 u_colorOffset   (vec4)     4 floats (r,g,b,a bias)
///   22     u_exposure      (float)
///   23     u_temperature   (float)
///   24     u_tint          (float)
///
/// The 5x4 matrix produced by [MatrixComposer] is 20 floats; the shader
/// expects a 4x4 matrix plus a separate offset vec4. We split accordingly.
///
/// ## GLSL matrix layout — column-major (Phase XI.0.4)
///
/// GLSL `mat4` and Flutter/Impeller's `setFloat`-driven uniform buffers
/// follow std140 layout: 16 sequential floats are interpreted as 4
/// columns of 4 floats each. The `MatrixComposer`'s 5x4 output is a
/// **row-major** 4-row × 5-col table (R/G/B/A output rows × R/G/B/A/bias
/// input columns). Uploading that row-by-row silently transposes the
/// matrix on the GPU, which only surfaces on asymmetric matrices —
/// saturation at `-1.0` turned everything green because the Rec.709
/// luma weights ended up per-input-channel instead of per-output-channel.
/// Brightness / contrast / exposure are symmetric and so looked fine.
///
/// See `test/engine/rendering/color_grading_matrix_upload_test.dart`
/// for the regression pin.
class ColorGradingShader {
  ColorGradingShader({
    required this.colorMatrix5x4,
    this.exposure = 0.0,
    this.temperature = 0.0,
    this.tint = 0.0,
  });

  /// 5x4 color matrix in the same layout [MatrixComposer] produces.
  final Float32List colorMatrix5x4;
  final double exposure;
  final double temperature;
  final double tint;

  ShaderPass toPass() {
    // Snapshot the 20-float matrix hash at build time.
    // [colorMatrix5x4] is the session-reused `matrixScratch` scratch
    // buffer (Phase VI.2) — its contents are overwritten every frame
    // in-place. Deferring the hash to `shouldRepaint` would compare
    // the current frame's buffer against itself. Also fold in the
    // three scalars so any one of them changing busts the hash.
    int h = Object.hash(exposure, temperature, tint);
    for (final v in colorMatrix5x4) {
      h = Object.hash(h, v);
    }
    return ShaderPass(
      assetKey: ShaderKeys.colorGrading,
      setUniforms: _setUniforms,
      contentHash: h,
    );
  }

  int _setUniforms(ui.FragmentShader shader, int start) {
    // Phase XI.0.4: pack the 20-float uniform block into [_packed] in
    // the order GLSL expects — 16 floats of mat4 column-major followed
    // by 4 floats of offset vec4 — then push them to the shader. Prior
    // to this fix the loop wrote row-major, which silently transposed
    // the matrix on the GPU. Pure packing is extracted so tests can
    // pin the column-major ordering without mocking `FragmentShader`.
    packUniformBlock(
      colorMatrix5x4,
      exposure: exposure,
      temperature: temperature,
      tint: tint,
      out: _packed,
    );
    for (int i = 0; i < _packed.length; i++) {
      shader.setFloat(start + i, _packed[i]);
    }
    return start + _packed.length;
  }

  /// Reusable scratch buffer so [_setUniforms] doesn't allocate on
  /// the per-frame paint hot path (Phase VI.2 convention).
  static final Float32List _packed = Float32List(23);

  /// Phase XI.0.4: pack the 5x4 source matrix + three scalars into the
  /// GLSL uniform layout. Extracted as pure-Dart + `@visibleForTesting`
  /// so a test can assert the column-major ordering without having to
  /// mock the base-class `ui.FragmentShader`.
  ///
  /// Layout written into [out] (length must be ≥ 23):
  ///   indices  0..15  — u_colorMatrix (mat4, **column-major**)
  ///   indices 16..19  — u_colorOffset (vec4: biases for R/G/B/A output)
  ///   index       20  — u_exposure
  ///   index       21  — u_temperature
  ///   index       22  — u_tint
  @visibleForTesting
  static void packUniformBlock(
    Float32List colorMatrix5x4, {
    required double exposure,
    required double temperature,
    required double tint,
    required Float32List out,
  }) {
    assert(colorMatrix5x4.length == 20,
        'expected 5x4 = 20 floats, got ${colorMatrix5x4.length}');
    assert(out.length >= 23, 'out buffer must hold ≥ 23 floats');
    // u_colorMatrix — column-major.
    for (int col = 0; col < 4; col++) {
      for (int row = 0; row < 4; row++) {
        out[col * 4 + row] = colorMatrix5x4[row * 5 + col];
      }
    }
    // u_colorOffset — biases (5th column of each row).
    for (int row = 0; row < 4; row++) {
      out[16 + row] = colorMatrix5x4[row * 5 + 4];
    }
    out[20] = exposure;
    out[21] = temperature;
    out[22] = tint;
  }
}
