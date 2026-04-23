import 'package:flutter_test/flutter_test.dart';

import 'package:image_editor/engine/layers/content_layer.dart';
import 'package:image_editor/engine/pipeline/edit_op_type.dart';
import 'package:image_editor/engine/pipeline/edit_operation.dart';

/// Phase XVI.1: pins the new `composeSubject` kind's serialization
/// contract so `AdjustmentLayer.toParams` / `fromOp` round-trips
/// the transform fields (`x`, `y`, `rotation`, `scale`) that every
/// other AdjustmentKind ignores. Without this, a user's subject
/// position would reset to centre on every session reload.
void main() {
  group('AdjustmentLayer.composeSubject transform round-trip', () {
    test('default construction still yields (0.5, 0.5, 0, 1)', () {
      const layer = AdjustmentLayer(
        id: 'subject-1',
        adjustmentKind: AdjustmentKind.composeSubject,
      );
      expect(layer.x, 0.5);
      expect(layer.y, 0.5);
      expect(layer.rotation, 0.0);
      expect(layer.scale, 1.0);
    });

    test('custom transform persists through toParams + fromOp', () {
      const layer = AdjustmentLayer(
        id: 'subject-2',
        adjustmentKind: AdjustmentKind.composeSubject,
        x: 0.3,
        y: 0.7,
        rotation: 0.4,
        scale: 1.5,
      );
      final op = EditOperation.create(
        type: EditOpType.adjustmentLayer,
        parameters: layer.toParams(),
      ).copyWith(id: layer.id);
      final reloaded = AdjustmentLayer.fromOp(op);
      expect(reloaded.adjustmentKind, AdjustmentKind.composeSubject);
      expect(reloaded.x, closeTo(0.3, 1e-9));
      expect(reloaded.y, closeTo(0.7, 1e-9));
      expect(reloaded.rotation, closeTo(0.4, 1e-9));
      expect(reloaded.scale, closeTo(1.5, 1e-9));
    });

    test('copyWith accepts transform overrides', () {
      const layer = AdjustmentLayer(
        id: 'subject-3',
        adjustmentKind: AdjustmentKind.composeSubject,
      );
      final moved = layer.copyWith(x: 0.2, scale: 2.0);
      expect(moved.x, 0.2);
      expect(moved.y, 0.5);
      expect(moved.scale, 2.0);
      expect(moved.rotation, 0.0);
    });

    test('backgroundRemoval default transform still matches', () {
      // Regression guard — relaxing the ctor to allow transforms
      // mustn't change the default behaviour for every other kind.
      const layer = AdjustmentLayer(
        id: 'bg-1',
        adjustmentKind: AdjustmentKind.backgroundRemoval,
      );
      expect(layer.x, 0.5);
      expect(layer.y, 0.5);
      expect(layer.rotation, 0.0);
      expect(layer.scale, 1.0);
    });
  });

  group('AdjustmentKind.composeSubject label + displayLabel', () {
    test('label is non-empty', () {
      expect(AdjustmentKind.composeSubject.label, isNotEmpty);
    });

    test('displayLabel is non-empty', () {
      const layer = AdjustmentLayer(
        id: 's',
        adjustmentKind: AdjustmentKind.composeSubject,
      );
      expect(layer.displayLabel, isNotEmpty);
    });
  });
}
