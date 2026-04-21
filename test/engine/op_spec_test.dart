import 'package:flutter_test/flutter_test.dart';

import 'package:image_editor/engine/pipeline/edit_op_type.dart';
import 'package:image_editor/engine/pipeline/op_spec.dart';

void main() {
  group('OpSpec', () {
    test('all five active categories have at least one spec registered', () {
      // Confirms no category was accidentally left empty after a refactor.
      // NOTE: OpCategory.optics was removed in Phase II.5 (see
      // docs/decisions/optics-tab.md). If lens correction work is scoped,
      // add it back to the enum and register its first OpSpec before
      // re-adding it here.
      expect(OpSpecs.forCategory(OpCategory.light), isNotEmpty);
      expect(OpSpecs.forCategory(OpCategory.color), isNotEmpty);
      expect(OpSpecs.forCategory(OpCategory.effects), isNotEmpty);
      expect(OpSpecs.forCategory(OpCategory.detail), isNotEmpty);
      expect(OpSpecs.forCategory(OpCategory.geometry), isNotEmpty);
    });

    test('byType returns the right spec', () {
      final brightness = OpSpecs.byType(EditOpType.brightness)!;
      expect(brightness.label, 'Brightness');
      expect(brightness.category, OpCategory.light);
      expect(brightness.min, -1);
      expect(brightness.max, 1);
      expect(brightness.identity, 0);
    });

    test('byType returns null for unknown type', () {
      expect(OpSpecs.byType('does.not.exist'), isNull);
    });

    test('isIdentity honors epsilon', () {
      final brightness = OpSpecs.byType(EditOpType.brightness)!;
      expect(brightness.isIdentity(0), true);
      expect(brightness.isIdentity(1e-5), true);
      expect(brightness.isIdentity(0.01), false);
    });

    test('hue spec has degree range', () {
      final hue = OpSpecs.byType(EditOpType.hue)!;
      expect(hue.min, -180);
      expect(hue.max, 180);
    });

    test('exposure has stops range', () {
      final exposure = OpSpecs.byType(EditOpType.exposure)!;
      expect(exposure.min, -2);
      expect(exposure.max, 2);
    });
  });
}
