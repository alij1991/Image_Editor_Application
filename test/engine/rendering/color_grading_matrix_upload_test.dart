import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image_editor/engine/pipeline/matrix_composer.dart';
import 'package:image_editor/engine/rendering/shaders/color_grading_shader.dart';

/// Phase XI.0.4 regression: `ColorGradingShader` must upload its 4x4
/// matrix to the GPU in **column-major** order. Prior to this phase the
/// loops were swapped (row-major upload) which silently transposed the
/// matrix on the GPU — B&W presets at `saturation = -1.0` produced a
/// green-tinted image because the Rec.709 luma weights ended up on the
/// input-G channel instead of the output R/G/B rows.
///
/// Brightness / contrast / exposure matrices are symmetric so the bug
/// was invisible on the regular tabs; only asymmetric matrices (sat,
/// hue, channel mixer) surface it.
///
/// The production upload path is [ColorGradingShader._setUniforms]. To
/// keep the test pure Dart (no `ui.FragmentShader` mocking — it's a
/// `base` class outside its library), that method delegates to the
/// static [ColorGradingShader.packUniformBlock] helper which writes
/// the 23-float block into a caller-owned buffer. Tests assert on the
/// buffer contents.
void main() {
  group('ColorGradingShader.packUniformBlock (Phase XI.0.4)', () {
    test('saturation(-1.0) packs column-major so luma rows stay rows',
        () {
      final m = MatrixComposer.saturation(-1.0);
      final out = Float32List(23);
      ColorGradingShader.packUniformBlock(
        m,
        exposure: 0,
        temperature: 0,
        tint: 0,
        out: out,
      );

      // 5x4 source layout (R_out, G_out, B_out, A_out):
      //   [0.2126, 0.7152, 0.0722, 0] | bias 0
      //   [0.2126, 0.7152, 0.0722, 0] | bias 0
      //   [0.2126, 0.7152, 0.0722, 0] | bias 0
      //   [0,      0,      0,      1] | bias 0
      // Column-major: column 0 (R_in coefficients for each output row)
      // must come first: [0.2126, 0.2126, 0.2126, 0].
      const tol = 1e-6;
      // Column 0 — indices 0..3: R_in coefficients for output R/G/B/A
      expect(out[0], closeTo(0.2126, tol));
      expect(out[1], closeTo(0.2126, tol));
      expect(out[2], closeTo(0.2126, tol));
      expect(out[3], closeTo(0.0, tol));
      // Column 1 — indices 4..7: G_in coefficients
      expect(out[4], closeTo(0.7152, tol));
      expect(out[5], closeTo(0.7152, tol));
      expect(out[6], closeTo(0.7152, tol));
      expect(out[7], closeTo(0.0, tol));
      // Column 2 — indices 8..11: B_in coefficients
      expect(out[8], closeTo(0.0722, tol));
      expect(out[9], closeTo(0.0722, tol));
      expect(out[10], closeTo(0.0722, tol));
      expect(out[11], closeTo(0.0, tol));
      // Column 3 — indices 12..15: A_in coefficients
      expect(out[12], closeTo(0.0, tol));
      expect(out[13], closeTo(0.0, tol));
      expect(out[14], closeTo(0.0, tol));
      expect(out[15], closeTo(1.0, tol));
      // Offset vec4 — indices 16..19: biases for R/G/B/A, all zero here
      expect(out[16], closeTo(0.0, tol));
      expect(out[17], closeTo(0.0, tol));
      expect(out[18], closeTo(0.0, tol));
      expect(out[19], closeTo(0.0, tol));
    });

    test('identity matrix packs as GLSL identity', () {
      final m = MatrixComposer.identity();
      final out = Float32List(23);
      ColorGradingShader.packUniformBlock(
        m,
        exposure: 0,
        temperature: 0,
        tint: 0,
        out: out,
      );
      // Column 0 → (1, 0, 0, 0), Column 1 → (0, 1, 0, 0), …
      expect(out.sublist(0, 4), [1.0, 0.0, 0.0, 0.0]);
      expect(out.sublist(4, 8), [0.0, 1.0, 0.0, 0.0]);
      expect(out.sublist(8, 12), [0.0, 0.0, 1.0, 0.0]);
      expect(out.sublist(12, 16), [0.0, 0.0, 0.0, 1.0]);
    });

    test('hue(90°) packs column-major (asymmetric matrix)', () {
      final m = MatrixComposer.hue(90);
      final out = Float32List(23);
      ColorGradingShader.packUniformBlock(
        m,
        exposure: 0,
        temperature: 0,
        tint: 0,
        out: out,
      );
      // For each (col, row), expected_index = col*4 + row,
      // expected_value = m[row*5 + col].
      for (int col = 0; col < 4; col++) {
        for (int row = 0; row < 4; row++) {
          expect(
            out[col * 4 + row],
            closeTo(m[row * 5 + col], 1e-6),
            reason: 'col=$col row=$row',
          );
        }
      }
    });

    test('brightness(+0.5) bias lands in u_colorOffset slot', () {
      final m = MatrixComposer.brightness(0.5);
      final out = Float32List(23);
      ColorGradingShader.packUniformBlock(
        m,
        exposure: 0,
        temperature: 0,
        tint: 0,
        out: out,
      );
      // Offset vec4 = (0.5, 0.5, 0.5, 0)
      expect(out[16], 0.5);
      expect(out[17], 0.5);
      expect(out[18], 0.5);
      expect(out[19], 0.0);
    });

    test('scalars land in the trailing 3 uniform slots', () {
      final m = MatrixComposer.identity();
      final out = Float32List(23);
      ColorGradingShader.packUniformBlock(
        m,
        exposure: -1.5,
        temperature: 0.3,
        tint: -0.25,
        out: out,
      );
      expect(out[20], closeTo(-1.5, 1e-6));
      expect(out[21], closeTo(0.3, 1e-6));
      expect(out[22], closeTo(-0.25, 1e-6));
    });
  });
}
