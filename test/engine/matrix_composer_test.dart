import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:image_editor/engine/pipeline/edit_op_type.dart';
import 'package:image_editor/engine/pipeline/edit_operation.dart';
import 'package:image_editor/engine/pipeline/edit_pipeline.dart';
import 'package:image_editor/engine/pipeline/matrix_composer.dart';

void main() {
  group('MatrixComposer', () {
    const composer = MatrixComposer();

    test('identity returns a 4x5 identity', () {
      final m = MatrixComposer.identity();
      expect(m.length, 20);
      expect(m[0], 1); // r row, r coeff
      expect(m[6], 1); // g row, g coeff
      expect(m[12], 1); // b row, b coeff
      expect(m[18], 1); // a row, a coeff
      expect(m[4], 0); // r row bias
      expect(m[9], 0); // g row bias
      expect(m[14], 0); // b row bias
    });

    test('empty pipeline composes to identity', () {
      final pipeline = EditPipeline.forOriginal('/tmp/img.jpg');
      final m = composer.compose(pipeline);
      expectClose(m, MatrixComposer.identity());
    });

    test('brightness composes into bias', () {
      final pipeline = EditPipeline.forOriginal('/tmp/img.jpg').append(
        EditOperation.create(
          type: EditOpType.brightness,
          parameters: {'value': 0.3},
        ),
      );
      final m = composer.compose(pipeline);
      expect(m[4], closeTo(0.3, 1e-6));
      expect(m[9], closeTo(0.3, 1e-6));
      expect(m[14], closeTo(0.3, 1e-6));
    });

    test('disabled ops are skipped', () {
      var pipeline = EditPipeline.forOriginal('/tmp/img.jpg');
      final op = EditOperation.create(
        type: EditOpType.brightness,
        parameters: {'value': 0.5},
      );
      pipeline = pipeline.append(op);
      final before = composer.compose(pipeline);
      pipeline = pipeline.toggleEnabled(op.id);
      final after = composer.compose(pipeline);
      expect(before[4], closeTo(0.5, 1e-6));
      expectClose(after, MatrixComposer.identity());
    });

    test('exposure = 0 stops is identity', () {
      final m = MatrixComposer.exposure(0);
      expect(m[0], closeTo(1, 1e-6));
      expect(m[6], closeTo(1, 1e-6));
      expect(m[12], closeTo(1, 1e-6));
    });

    test('saturation 0 is identity', () {
      final m = MatrixComposer.saturation(0);
      expectClose(m, MatrixComposer.identity(), tolerance: 1e-6);
    });

    test('hue 0 degrees is identity', () {
      final m = MatrixComposer.hue(0);
      expectClose(m, MatrixComposer.identity(), tolerance: 1e-5);
    });

    test('non-matrix op is ignored', () {
      final pipeline = EditPipeline.forOriginal('/tmp/img.jpg').append(
        EditOperation.create(
          type: EditOpType.vignette,
          parameters: {'amount': 0.5},
        ),
      );
      final m = composer.compose(pipeline);
      expectClose(m, MatrixComposer.identity(), tolerance: 1e-6);
    });
  });
}

void expectClose(
  Float32List a,
  Float32List b, {
  double tolerance = 1e-6,
}) {
  expect(a.length, b.length);
  for (int i = 0; i < a.length; i++) {
    expect(a[i], closeTo(b[i], tolerance), reason: 'index $i');
  }
}
