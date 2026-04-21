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

    // =============================================================
    // Phase III.4: LUT intensity participates in preset amount.
    // Previously a LUT-backed preset applied at 50% still showed the
    // LUT at its full preset-configured intensity — the `intensity`
    // param wasn't in the interpolating set. The registry now tags
    // `filter.lut3d` with `interpolatingKeys: {'intensity'}` so the
    // Amount slider scales LUT strength as the user expects.
    // =============================================================

    test('LUT intensity scales linearly with preset amount', () {
      final p = make([
        op(EditOpType.lut3d, {
          'assetPath': 'assets/luts/cool_33.png',
          'intensity': 0.8,
        }),
      ]);
      final half = intensity.blend(p, 0.5);
      expect(half.first.type, EditOpType.lut3d);
      expect(half.first.doubleParam('intensity'), closeTo(0.4, 0.001));
      // assetPath must pass through literal — it's a String, not a num,
      // so the blend() non-interpolating branch handles it.
      expect(half.first.parameters['assetPath'], 'assets/luts/cool_33.png');
    });

    test('LUT at amount 1.0 reproduces preset-literal intensity', () {
      final p = make([
        op(EditOpType.lut3d, {
          'assetPath': 'assets/luts/warm_33.png',
          'intensity': 0.85,
        }),
      ]);
      final full = intensity.blend(p, 1.0);
      expect(full.first.doubleParam('intensity'), closeTo(0.85, 0.001));
    });

    test('LUT at amount 0 returns empty (op dropped with the rest)', () {
      final p = make([
        op(EditOpType.lut3d, {
          'assetPath': 'assets/luts/mono_33.png',
          'intensity': 1.0,
        }),
      ]);
      final none = intensity.blend(p, 0.0);
      expect(none, isEmpty);
    });

    test(
        'LUT intensity at amount > 1.0 linearly extrapolates from baseline '
        '(renderer clamps for the shader)', () {
      // PresetIntensity itself doesn't clamp lut3d.intensity because
      // there's no OpSpec to read min/max from — by design, to keep
      // the blend logic op-agnostic. The editor_session renderer
      // clamps the value to [0, 1] before passing it to the Lut3d
      // shader. Pin the blend-math invariant here.
      final p = make([
        op(EditOpType.lut3d, {'intensity': 0.8}),
      ]);
      final over = intensity.blend(p, 1.5);
      // 1.5 × 0.8 = 1.2 (unclamped — renderer handles the shader side)
      expect(over.first.doubleParam('intensity'), closeTo(1.2, 0.001));
    });

    test('LUT op with no intensity param is left untouched', () {
      // Defensive: a saved pipeline might miss the intensity param
      // (e.g. third-party import). Blend should not add one and should
      // not crash.
      final p = make([
        op(EditOpType.lut3d, {'assetPath': 'assets/luts/foo.png'}),
      ]);
      final result = intensity.blend(p, 0.5);
      expect(result.first.parameters.containsKey('intensity'), isFalse);
      expect(result.first.parameters['assetPath'], 'assets/luts/foo.png');
    });
  });
}
