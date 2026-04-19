import 'package:flutter_test/flutter_test.dart';

import 'package:image_editor/engine/pipeline/edit_op_type.dart';
import 'package:image_editor/engine/pipeline/edit_operation.dart';
import 'package:image_editor/engine/presets/preset.dart';
import 'package:image_editor/engine/presets/preset_intensity.dart';

void main() {
  const intensity = PresetIntensity();

  Preset make(List<EditOperation> ops) => Preset(
        id: 'test.preset',
        name: 'Test',
        category: 'test',
        builtIn: false,
        operations: ops,
      );

  EditOperation op(String type, Map<String, dynamic> params) =>
      EditOperation.create(type: type, parameters: params);

  group('PresetIntensity.blend', () {
    test('amount 0 returns no ops', () {
      final p = make([
        op(EditOpType.contrast, {'value': 0.3}),
        op(EditOpType.vibrance, {'value': 0.2}),
      ]);
      final result = intensity.blend(p, 0.0);
      expect(result, isEmpty);
    });

    test('amount 1 reproduces preset exactly', () {
      final p = make([
        op(EditOpType.contrast, {'value': 0.3}),
        op(EditOpType.saturation, {'value': -0.1}),
      ]);
      final result = intensity.blend(p, 1.0);
      expect(result.length, 2);
      expect(result[0].doubleParam('value'), closeTo(0.3, 0.001));
      expect(result[1].doubleParam('value'), closeTo(-0.1, 0.001));
    });

    test('amount 0.5 interpolates halfway', () {
      final p = make([
        op(EditOpType.contrast, {'value': 0.4}),
        op(EditOpType.shadows, {'value': 0.2}),
      ]);
      final result = intensity.blend(p, 0.5);
      expect(result[0].doubleParam('value'), closeTo(0.2, 0.001));
      expect(result[1].doubleParam('value'), closeTo(0.1, 0.001));
    });

    test('amount 1.5 extrapolates linearly', () {
      final p = make([
        op(EditOpType.contrast, {'value': 0.2}),
      ]);
      final result = intensity.blend(p, 1.5);
      // 1.5 × 0.2 = 0.3
      expect(result[0].doubleParam('value'), closeTo(0.3, 0.001));
    });

    test('amount beyond 1.5 clamps to 1.5 (not the spec max)', () {
      final p = make([
        op(EditOpType.contrast, {'value': 0.1}),
      ]);
      final result = intensity.blend(p, 99.0);
      // Should behave as if amount == 1.5 → 0.15.
      expect(result[0].doubleParam('value'), closeTo(0.15, 0.001));
    });

    test('amount 1.5 clamps per-op value to OpSpec.max', () {
      // Contrast spec max is 1.0, so 1.5 × 0.8 = 1.2 clamps to 1.0.
      final p = make([
        op(EditOpType.contrast, {'value': 0.8}),
      ]);
      final result = intensity.blend(p, 1.5);
      expect(result[0].doubleParam('value'), closeTo(1.0, 0.001));
    });

    test('negative amount is clamped to 0', () {
      final p = make([
        op(EditOpType.contrast, {'value': 0.3}),
      ]);
      final result = intensity.blend(p, -0.5);
      expect(result, isEmpty);
    });

    test('shape params (vignette feather) pass through at amount > 0', () {
      final p = make([
        op(EditOpType.vignette, {
          'amount': 0.4,
          'feather': 0.55,
          'roundness': 0.5,
        }),
      ]);
      final result = intensity.blend(p, 0.6);
      // Vignette amount interpolates (0.6 × 0.4 = 0.24).
      expect(result[0].doubleParam('amount'), closeTo(0.24, 0.001));
      // Feather is a shape param — pass through literal.
      expect(result[0].doubleParam('feather'), closeTo(0.55, 0.001));
      expect(result[0].doubleParam('roundness'), closeTo(0.5, 0.001));
    });

    test('fresh UUIDs on every blend invocation', () {
      final p = make([
        op(EditOpType.contrast, {'value': 0.2}),
      ]);
      final a = intensity.blend(p, 1.0);
      final b = intensity.blend(p, 1.0);
      expect(a[0].id, isNot(equals(b[0].id)));
    });

    test('multiple ops blend independently at the same amount', () {
      final p = make([
        op(EditOpType.contrast, {'value': 0.4}),
        op(EditOpType.vibrance, {'value': 0.2}),
        op(EditOpType.saturation, {'value': -0.1}),
      ]);
      final result = intensity.blend(p, 0.25);
      expect(result[0].doubleParam('value'), closeTo(0.1, 0.001));
      expect(result[1].doubleParam('value'), closeTo(0.05, 0.001));
      expect(result[2].doubleParam('value'), closeTo(-0.025, 0.001));
    });
  });
}
