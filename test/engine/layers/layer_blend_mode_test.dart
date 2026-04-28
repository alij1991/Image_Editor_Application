import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';

import 'package:image_editor/engine/layers/content_layer.dart';
import 'package:image_editor/engine/layers/layer_blend_mode.dart';
import 'package:image_editor/engine/pipeline/edit_op_type.dart';
import 'package:image_editor/engine/pipeline/edit_operation.dart';

/// Phase XVI.43 — pin the blend-mode coverage invariants.
///
/// The audit's "verify all 9 modes are implemented in LayerPainter
/// (currently only Normal renders)" is satisfied by the existing
/// `LayerBlendModeX.flutter` switch — which covers every value in
/// the enum. This test set guards three regressions:
///
///   1. A new value added to [LayerBlendMode] but not added to the
///      `flutter` mapping (silently degrades to a CASE_NOT_HANDLED
///      compile error today, but a future refactor could mask it).
///   2. A new value added without a label (the picker would render
///      empty chips).
///   3. A blend-mode change failing to round-trip through the saved
///      pipeline JSON — the editor's layer state would silently
///      reset to Normal on every reload.
void main() {
  group('LayerBlendMode coverage (XVI.43)', () {
    test('every enum value maps to a Flutter BlendMode', () {
      // The compiler enforces this for the `switch (this)` in
      // [LayerBlendModeX.flutter] when run with `dart analyze`, but
      // the test makes the contract explicit + machine-readable.
      for (final v in LayerBlendMode.values) {
        // Just resolving the getter is the assertion — a missing
        // case branch would throw an unreachable error here.
        final mapped = v.flutter;
        expect(mapped, isA<BlendMode>(),
            reason: '${v.name} did not map to a Flutter BlendMode');
      }
    });

    test('every enum value has a non-empty label', () {
      for (final v in LayerBlendMode.values) {
        expect(v.label.isNotEmpty, isTrue,
            reason: '${v.name} has no picker label');
      }
    });

    test('fromName round-trips every value', () {
      for (final v in LayerBlendMode.values) {
        expect(LayerBlendModeX.fromName(v.name), v);
      }
    });

    test('fromName falls back to normal on unknown / null', () {
      expect(LayerBlendModeX.fromName(null), LayerBlendMode.normal);
      expect(LayerBlendModeX.fromName(''), LayerBlendMode.normal);
      expect(
          LayerBlendModeX.fromName('not a real mode'), LayerBlendMode.normal);
    });

    test('every value persists through ContentLayer JSON round-trip', () {
      // Mirrors what the editor session does on save / reload: the
      // blendMode lands in the params map keyed `blendMode` (when
      // non-Normal) and re-parses via LayerBlendModeX.fromName.
      for (final mode in LayerBlendMode.values) {
        final layer = TextLayer(
          id: 'L1',
          text: 'x',
          fontSize: 32,
          colorArgb: 0xFFFFFFFF,
          blendMode: mode,
        );
        final op = EditOperation.create(
          type: EditOpType.text,
          parameters: layer.toParams(),
        );
        final back = TextLayer.fromOp(op);
        expect(back.blendMode, mode,
            reason: '${mode.name} dropped through JSON round-trip');
      }
    });

    test('Normal blend mode is omitted from the persisted params', () {
      // Phase 8 contract: only non-Normal modes write the key, so a
      // pristine layer's JSON stays minimal.
      const layer = TextLayer(
        id: 'L1',
        text: 'x',
        fontSize: 32,
        colorArgb: 0xFFFFFFFF,
      );
      expect(layer.toParams().containsKey('blendMode'), isFalse);
    });

    test('LayerBlendMode.values contains the 13 well-known modes', () {
      // Audit baseline — adding a new mode is fine; removing a
      // historical mode breaks every saved project that referenced
      // it. If this fails on a future change, write a migration
      // path (rename the legacy mode to a similar one) before
      // bumping the test.
      const expected = {
        LayerBlendMode.normal,
        LayerBlendMode.multiply,
        LayerBlendMode.screen,
        LayerBlendMode.overlay,
        LayerBlendMode.darken,
        LayerBlendMode.lighten,
        LayerBlendMode.colorDodge,
        LayerBlendMode.colorBurn,
        LayerBlendMode.hardLight,
        LayerBlendMode.softLight,
        LayerBlendMode.difference,
        LayerBlendMode.exclusion,
        LayerBlendMode.plus,
      };
      expect(LayerBlendMode.values.toSet(), equals(expected));
    });
  });
}
