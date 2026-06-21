import 'package:flutter_test/flutter_test.dart';

import 'package:image_editor/engine/pipeline/edit_op_type.dart';
import 'package:image_editor/engine/pipeline/op_spec.dart';

/// XVI.117 (C2) — the depth-aware Lens Blur control is a dead control
/// (no bundled depth model, DepthEstimator never instantiated), so its
/// specs are marked `hidden: true`. These tests pin the contract:
///   - hidden specs never reach the UI ([OpSpecs.forCategory]),
///   - but stay in [OpSpecs.all] / [paramsForType] so a legacy pipeline
///     op still serialises + identity-collapses,
///   - and NO other shipping control is accidentally hidden.
void main() {
  group('OpSpec.hidden', () {
    test('defaults to false', () {
      const s = OpSpec(
        type: 'x',
        label: 'X',
        category: OpCategory.effects,
        min: 0,
        max: 1,
        identity: 0,
      );
      expect(s.hidden, isFalse);
    });

    test('Lens Blur is excluded from the Effects panel (forCategory)', () {
      final effects = OpSpecs.forCategory(OpCategory.effects);
      expect(
        effects.where((s) => s.type == EditOpType.lensBlur),
        isEmpty,
        reason: 'hidden lens-blur specs must not render in the panel',
      );
      // The Effects tab itself must still have content (other ops).
      expect(effects, isNotEmpty);
    });

    test('forCategory excludes hidden specs across every category', () {
      for (final cat in OpCategory.values) {
        expect(
          OpSpecs.forCategory(cat).where((s) => s.hidden),
          isEmpty,
          reason: 'no hidden spec should survive forCategory($cat)',
        );
      }
    });

    test('Lens Blur specs remain in OpSpecs.all (machinery intact)', () {
      final lensBlur =
          OpSpecs.all.where((s) => s.type == EditOpType.lensBlur).toList();
      expect(lensBlur, hasLength(4),
          reason: 'aperture + focusX + focusY + bokehShape');
      expect(lensBlur.every((s) => s.hidden), isTrue);
      // paramsForType (identity-collapse / serialisation path) still sees them.
      expect(OpSpecs.paramsForType(EditOpType.lensBlur), hasLength(4));
    });

    test('lensBlur is the ONLY hidden op (no shipping control hidden)', () {
      final hiddenTypes =
          OpSpecs.all.where((s) => s.hidden).map((s) => s.type).toSet();
      expect(hiddenTypes, equals(<String>{EditOpType.lensBlur}));
    });
  });
}
