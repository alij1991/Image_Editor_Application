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

  /// Phase VI.2 — `composeInto` scratch-buffer contract.
  ///
  /// Pins the "zero allocation in the hot path" invariant by asserting
  /// that the returned buffer IS the caller's buffer (by identity), that
  /// repeated calls produce byte-identical output to `compose`, and that
  /// the internal scratch buffers do not leak across pipelines.
  group('MatrixComposer.composeInto', () {
    const composer = MatrixComposer();

    EditPipeline pipelineOf(List<EditOperation> ops) {
      var p = EditPipeline.forOriginal('/tmp/img.jpg');
      for (final op in ops) {
        p = p.append(op);
      }
      return p;
    }

    test('returns the caller-provided buffer (same reference)', () {
      final out = Float32List(20);
      final pipeline = pipelineOf([
        EditOperation.create(
          type: EditOpType.brightness,
          parameters: {'value': 0.3},
        ),
      ]);
      final returned = composer.composeInto(pipeline, out);
      expect(identical(returned, out), isTrue,
          reason: 'composeInto must return the caller buffer for '
              'zero-allocation hot paths.');
    });

    test('empty pipeline fills [out] with identity', () {
      final out = Float32List(20);
      // Dirty the buffer so the fill is observable.
      for (int i = 0; i < 20; i++) {
        out[i] = -9.0;
      }
      final pipeline = EditPipeline.forOriginal('/tmp/img.jpg');
      composer.composeInto(pipeline, out);
      expectClose(out, MatrixComposer.identity());
    });

    test('single-op result matches compose() byte-for-byte', () {
      final pipeline = pipelineOf([
        EditOperation.create(
          type: EditOpType.brightness,
          parameters: {'value': 0.25},
        ),
      ]);
      final fromCompose = composer.compose(pipeline);
      final intoBuf = Float32List(20);
      composer.composeInto(pipeline, intoBuf);
      expectClose(intoBuf, fromCompose);
    });

    test('multi-op result matches compose() byte-for-byte', () {
      final pipeline = pipelineOf([
        EditOperation.create(
          type: EditOpType.brightness,
          parameters: {'value': 0.3},
        ),
        EditOperation.create(
          type: EditOpType.contrast,
          parameters: {'value': 0.2},
        ),
        EditOperation.create(
          type: EditOpType.saturation,
          parameters: {'value': -0.15},
        ),
        EditOperation.create(
          type: EditOpType.hue,
          parameters: {'value': 12.0},
        ),
      ]);
      final fromCompose = composer.compose(pipeline);
      final intoBuf = Float32List(20);
      composer.composeInto(pipeline, intoBuf);
      expectClose(intoBuf, fromCompose);
    });

    test('disabled ops are skipped', () {
      var pipeline = EditPipeline.forOriginal('/tmp/img.jpg');
      final op = EditOperation.create(
        type: EditOpType.brightness,
        parameters: {'value': 0.5},
      );
      pipeline = pipeline.append(op).toggleEnabled(op.id);
      final out = Float32List(20);
      composer.composeInto(pipeline, out);
      expectClose(out, MatrixComposer.identity());
    });

    test('non-matrix op is ignored', () {
      final pipeline = pipelineOf([
        EditOperation.create(
          type: EditOpType.vignette,
          parameters: {'amount': 0.5},
        ),
      ]);
      final out = Float32List(20);
      composer.composeInto(pipeline, out);
      expectClose(out, MatrixComposer.identity(), tolerance: 1e-6);
    });

    test('1000 iterations on the same buffer stay deterministic + '
        'return the same reference every call', () {
      final pipeline = pipelineOf([
        EditOperation.create(
          type: EditOpType.brightness,
          parameters: {'value': 0.1},
        ),
        EditOperation.create(
          type: EditOpType.saturation,
          parameters: {'value': 0.2},
        ),
        EditOperation.create(
          type: EditOpType.exposure,
          parameters: {'value': 0.5},
        ),
      ]);
      final reference = composer.compose(pipeline);
      final scratch = Float32List(20);
      for (int i = 0; i < 1000; i++) {
        final returned = composer.composeInto(pipeline, scratch);
        expect(identical(returned, scratch), isTrue,
            reason: 'iter $i: scratch identity broken');
        expectClose(scratch, reference,
            tolerance: 1e-6);
      }
    });

    test('reusing the buffer across DIFFERENT pipelines is safe '
        '(no stale state from prior composition)', () {
      final scratch = Float32List(20);

      // First pipeline: brightness only.
      final p1 = pipelineOf([
        EditOperation.create(
          type: EditOpType.brightness,
          parameters: {'value': 0.4},
        ),
      ]);
      composer.composeInto(p1, scratch);
      final snapshot1 = Float32List.fromList(scratch);

      // Second pipeline: contrast only.
      final p2 = pipelineOf([
        EditOperation.create(
          type: EditOpType.contrast,
          parameters: {'value': 0.3},
        ),
      ]);
      composer.composeInto(p2, scratch);

      // Must match a fresh compose of p2 (not p1 * p2 mixed).
      final expected2 = composer.compose(p2);
      expectClose(scratch, expected2);

      // And snapshot1 must match a fresh compose of p1 (proving
      // the reused buffer preserved p1's output while it was alive).
      final expected1 = composer.compose(p1);
      expectClose(snapshot1, expected1);
    });

    test('empty pipeline after non-empty reuse resets to identity '
        '(stale scratch not leaked)', () {
      final scratch = Float32List(20);

      // Contaminate scratch via a non-empty pipeline.
      composer.composeInto(
        pipelineOf([
          EditOperation.create(
            type: EditOpType.brightness,
            parameters: {'value': 0.5},
          ),
        ]),
        scratch,
      );
      expect(scratch[4], closeTo(0.5, 1e-6));

      // Now feed an empty pipeline. Must collapse to identity, not
      // retain the 0.5 brightness from the prior call.
      composer.composeInto(
        EditPipeline.forOriginal('/tmp/img.jpg'),
        scratch,
      );
      expectClose(scratch, MatrixComposer.identity());
    });

    test('asserts when out.length != 20', () {
      expect(
        () => composer.composeInto(
          EditPipeline.forOriginal('/tmp/img.jpg'),
          Float32List(19),
        ),
        throwsA(isA<AssertionError>()),
      );
    });

    test('compose() returns a fresh buffer every call (backward compat)', () {
      final pipeline = pipelineOf([
        EditOperation.create(
          type: EditOpType.brightness,
          parameters: {'value': 0.2},
        ),
      ]);
      final a = composer.compose(pipeline);
      final b = composer.compose(pipeline);
      expect(identical(a, b), isFalse,
          reason: 'compose() must allocate a fresh buffer so callers '
              '(like preset_thumbnail_cache) can safely retain it.');
      expectClose(a, b);
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
