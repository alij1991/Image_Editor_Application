import 'package:flutter_test/flutter_test.dart';

import 'package:image_editor/engine/pipeline/edit_op_type.dart';
import 'package:image_editor/engine/pipeline/edit_operation.dart';
import 'package:image_editor/engine/pipeline/edit_pipeline.dart';
import 'package:image_editor/engine/pipeline/pipeline_extensions.dart';
import 'package:image_editor/engine/pipeline/tone_curve_set.dart';

/// Tests for the master tone-curve points reader. The session-side
/// setter (`EditorSession.setToneCurve`) is integration-tested on
/// device — it touches the LUT bake which needs a real GPU.
void main() {
  EditPipeline withCurve(List<List<double>> points) =>
      EditPipeline.forOriginal('/tmp/img.jpg').append(
        EditOperation.create(
          type: EditOpType.toneCurve,
          parameters: {
            'points': [
              for (final p in points) [p[0], p[1]],
            ],
          },
        ),
      );

  group('toneCurvePoints reader', () {
    test('returns null when the pipeline has no toneCurve op', () {
      final p = EditPipeline.forOriginal('/tmp/img.jpg');
      expect(p.toneCurvePoints, isNull);
    });

    test('returns null when only sStrength is set (legacy s-curve)', () {
      final p = EditPipeline.forOriginal('/tmp/img.jpg').append(
        EditOperation.create(
          type: EditOpType.toneCurve,
          parameters: {'sStrength': 0.4},
        ),
      );
      expect(p.toneCurvePoints, isNull);
    });

    test('returns the parsed points list when set', () {
      final p = withCurve([
        [0, 0],
        [0.3, 0.45],
        [0.7, 0.9],
        [1, 1],
      ]);
      final pts = p.toneCurvePoints;
      expect(pts, isNotNull);
      expect(pts!.length, 4);
      expect(pts[1][0], 0.3);
      expect(pts[1][1], 0.45);
    });

    test('returns null for an identity-shaped curve (no visible effect)',
        () {
      // Five points all sitting on the y=x diagonal — bakes to the
      // same LUT as no curve at all, so the session would pay the
      // bake cost for nothing.
      final p = withCurve([
        [0, 0],
        [0.25, 0.25],
        [0.5, 0.5],
        [0.75, 0.75],
        [1, 1],
      ]);
      expect(p.toneCurvePoints, isNull);
    });

    test('skips malformed entries inside the points list', () {
      final p = EditPipeline.forOriginal('/tmp/img.jpg').append(
        EditOperation.create(
          type: EditOpType.toneCurve,
          parameters: {
            'points': [
              [0, 0],
              ['oops', 'wrong types'],
              [0.5, 0.8],
              [1, 1],
            ],
          },
        ),
      );
      final pts = p.toneCurvePoints;
      expect(pts, isNotNull);
      // The malformed entry was dropped, the others survived.
      expect(pts!.length, 3);
    });

    test('returns null when the toneCurve op is disabled', () {
      var p = withCurve([
        [0, 0],
        [0.4, 0.7],
        [1, 1],
      ]);
      final id = p.operations.first.id;
      p = p.toggleEnabled(id);
      expect(p.toneCurvePoints, isNull);
    });

    test('returns the red channel via toneCurves when set', () {
      final p = EditPipeline.forOriginal('/tmp/img.jpg').append(
        EditOperation.create(
          type: EditOpType.toneCurve,
          parameters: {
            'red': [
              [0, 0],
              [0.5, 0.7],
              [1, 1],
            ],
          },
        ),
      );
      final set = p.toneCurves;
      expect(set, isNotNull);
      // Red is set, master/green/blue are identity (null).
      expect(set!.master, isNull);
      expect(set.red, isNotNull);
      expect(set.red![1][1], 0.7);
      expect(set.green, isNull);
      expect(set.blue, isNull);
      // The master-only reader still answers null because the master
      // channel itself is identity.
      expect(p.toneCurvePoints, isNull);
    });

    test('reads all four channels independently', () {
      final p = EditPipeline.forOriginal('/tmp/img.jpg').append(
        EditOperation.create(
          type: EditOpType.toneCurve,
          parameters: {
            'points': [[0, 0], [0.5, 0.6], [1, 1]],
            'red': [[0, 0], [0.5, 0.7], [1, 1]],
            'green': [[0, 0], [0.5, 0.4], [1, 1]],
            'blue': [[0, 0], [0.5, 0.3], [1, 1]],
          },
        ),
      );
      final set = p.toneCurves;
      expect(set, isNotNull);
      expect(set!.master, isNotNull);
      expect(set.master![1][1], 0.6);
      expect(set.red![1][1], 0.7);
      expect(set.green![1][1], 0.4);
      expect(set.blue![1][1], 0.3);
    });

    test('cacheKey is stable across rebuilds with the same shape', () {
      final a = ToneCurveSet(
        master: [[0, 0], [0.5, 0.8], [1, 1]],
        red: [[0, 0], [0.5, 0.7], [1, 1]],
      );
      final b = ToneCurveSet(
        master: [[0, 0], [0.5, 0.8], [1, 1]],
        red: [[0, 0], [0.5, 0.7], [1, 1]],
      );
      expect(a.cacheKey, equals(b.cacheKey));
    });

    test('cacheKey changes when any channel mutates', () {
      final a = ToneCurveSet(red: [[0, 0], [0.5, 0.7], [1, 1]]);
      final b = ToneCurveSet(red: [[0, 0], [0.5, 0.71], [1, 1]]);
      expect(a.cacheKey, isNot(equals(b.cacheKey)));
    });

    test('respects op order — first enabled toneCurve op wins', () {
      // The session only ever writes one toneCurve op, but the
      // reader is defensive in case a future merge writes two.
      final p = EditPipeline.forOriginal('/tmp/img.jpg')
          .append(
            EditOperation.create(
              type: EditOpType.toneCurve,
              parameters: {
                'points': [
                  [0, 0],
                  [0.5, 0.8],
                  [1, 1],
                ],
              },
            ),
          )
          .append(
            EditOperation.create(
              type: EditOpType.toneCurve,
              parameters: {
                'points': [
                  [0, 0],
                  [0.5, 0.2],
                  [1, 1],
                ],
              },
            ),
          );
      // Reader iterates in order, so the FIRST enabled match is
      // returned.
      final pts = p.toneCurvePoints;
      expect(pts, isNotNull);
      expect(pts![1][1], 0.8);
    });
  });
}
