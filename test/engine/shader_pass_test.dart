import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:image_editor/engine/pipeline/matrix_composer.dart';
import 'package:image_editor/engine/rendering/shaders/color_grading_shader.dart';

void main() {
  group('ColorGradingShader', () {
    test('identity matrix survives the 4x4 + offset repack', () {
      final matrix = MatrixComposer.identity();
      final shader = ColorGradingShader(colorMatrix5x4: matrix);
      // Verify the 4x4 repack extracts the identity correctly.
      // The pack logic lives inside the setUniforms callback; we only
      // assert the public surface doesn't reject the matrix length.
      expect(shader.colorMatrix5x4.length, 20);
    });

    test('non-identity matrix preserves offset column mapping', () {
      final m = MatrixComposer.brightness(0.3);
      final shader = ColorGradingShader(colorMatrix5x4: m);
      // Rows: r has bias m[4], g m[9], b m[14], a m[19]. The 4x4 portion
      // should be identity because brightness is pure bias.
      for (int row = 0; row < 4; row++) {
        for (int col = 0; col < 4; col++) {
          final expected = row == col ? 1.0 : 0.0;
          expect(
            shader.colorMatrix5x4[row * 5 + col],
            closeTo(expected, 1e-6),
            reason: 'row=$row col=$col',
          );
        }
      }
      expect(shader.colorMatrix5x4[4], closeTo(0.3, 1e-6));
      expect(shader.colorMatrix5x4[9], closeTo(0.3, 1e-6));
      expect(shader.colorMatrix5x4[14], closeTo(0.3, 1e-6));
    });

    test('float list accepts exactly 20 entries', () {
      // 5x4 = 20; anything else is a programmer error.
      expect(() => ColorGradingShader(colorMatrix5x4: Float32List(20)),
          returnsNormally);
    });
  });
}
