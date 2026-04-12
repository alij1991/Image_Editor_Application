import 'dart:typed_data';
import 'dart:ui' as ui;

import '../shader_keys.dart';
import '../shader_pass.dart';

/// Dart-side wrapper for `shaders/color_grading.frag`.
///
/// Uniform layout (GLSL -> Flutter setFloat indices):
///   0..1   u_size          (vec2)     set by ShaderRenderer
///   2..17  u_colorMatrix   (mat4)     16 floats, row-major 4x4
///   18..21 u_colorOffset   (vec4)     4 floats (r,g,b,a bias)
///   22     u_exposure      (float)
///   23     u_temperature   (float)
///   24     u_tint          (float)
///
/// The 5x4 matrix produced by [MatrixComposer] is 20 floats; the shader
/// expects a 4x4 matrix plus a separate offset vec4. We split accordingly.
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
    return ShaderPass(
      assetKey: ShaderKeys.colorGrading,
      setUniforms: _setUniforms,
    );
  }

  int _setUniforms(ui.FragmentShader shader, int start) {
    // Unpack 5x4 (20 floats in layout r0..r3|r5..r8|r10..r13|r15..r18) into
    // a 4x4 matrix plus an offset vec4.
    // 5x4 row-major has 5 cols (r,g,b,a,bias); the 4x4 uniform wants the
    // first 4 cols, and the offset uniform takes the bias column.
    var idx = start;
    for (int row = 0; row < 4; row++) {
      for (int col = 0; col < 4; col++) {
        shader.setFloat(idx++, colorMatrix5x4[row * 5 + col]);
      }
    }
    // u_colorOffset (vec4)
    for (int row = 0; row < 4; row++) {
      shader.setFloat(idx++, colorMatrix5x4[row * 5 + 4]);
    }
    shader.setFloat(idx++, exposure);
    shader.setFloat(idx++, temperature);
    shader.setFloat(idx++, tint);
    return idx;
  }
}
