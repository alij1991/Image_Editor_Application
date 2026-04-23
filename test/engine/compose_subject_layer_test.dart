import 'package:flutter_test/flutter_test.dart';

import 'package:image_editor/engine/layers/content_layer.dart';
import 'package:image_editor/engine/pipeline/edit_op_type.dart';
import 'package:image_editor/engine/pipeline/edit_operation.dart';

/// Phase XVI.11: pins the transform round-trip for the
/// [AdjustmentKind.composeSubject] kind. Every other adjustment
/// layer uses a fixed `x=0.5, y=0.5, rotation=0, scale=1`; compose
/// subject is the exception, and losing its transform on session
/// reload would reset the user's drag / scale / rotate to centred.
void main() {
  group('AdjustmentLayer.composeSubject transform round-trip', () {
    test('default construction yields (0.5, 0.5, 0, 1)', () {
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

    test('non-subject kinds still round-trip at default transform', () {
      // Regression guard — relaxing the ctor to allow transforms
      // must not change default behaviour for every other kind.
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

  group('AdjustmentLayer.composeSubject edge-refine round-trip (XVI.15)', () {
    test('defaults are zero for both refine fields', () {
      const layer = AdjustmentLayer(
        id: 's',
        adjustmentKind: AdjustmentKind.composeSubject,
      );
      expect(layer.edgeFeatherPx, 0.0);
      expect(layer.decontamStrength, 0.0);
    });

    test('custom refine values persist through toParams + fromOp', () {
      const layer = AdjustmentLayer(
        id: 's',
        adjustmentKind: AdjustmentKind.composeSubject,
        edgeFeatherPx: 4.5,
        decontamStrength: 0.7,
      );
      final op = EditOperation.create(
        type: EditOpType.adjustmentLayer,
        parameters: layer.toParams(),
      ).copyWith(id: layer.id);
      final reloaded = AdjustmentLayer.fromOp(op);
      expect(reloaded.edgeFeatherPx, closeTo(4.5, 1e-9));
      expect(reloaded.decontamStrength, closeTo(0.7, 1e-9));
    });

    test('copyWith accepts refine overrides', () {
      const layer = AdjustmentLayer(
        id: 's',
        adjustmentKind: AdjustmentKind.composeSubject,
      );
      final refined = layer.copyWith(edgeFeatherPx: 2.0, decontamStrength: 0.5);
      expect(refined.edgeFeatherPx, 2.0);
      expect(refined.decontamStrength, 0.5);
      // Transform fields untouched.
      expect(refined.x, 0.5);
      expect(refined.y, 0.5);
      expect(refined.scale, 1.0);
    });

    test('zero refine values are not serialised', () {
      // Round-trip guard: a default-zero refine on a plain bg
      // removal layer shouldn't add keys to its params map
      // (keeps persisted pipelines small).
      const layer = AdjustmentLayer(
        id: 'bg',
        adjustmentKind: AdjustmentKind.backgroundRemoval,
      );
      final params = layer.toParams();
      expect(params.containsKey('edgeFeatherPx'), isFalse);
      expect(params.containsKey('decontamStrength'), isFalse);
    });

    test('out-of-range persisted values are clamped on load', () {
      // Hostile input: an old / hand-edited pipeline JSON with
      // refine values outside the UI's `[0, 12]` / `[0, 1]` ranges.
      // `fromOp` must clamp so the service can't see garbage.
      final op = EditOperation.create(
        type: EditOpType.adjustmentLayer,
        parameters: {
          'adjustmentKind': AdjustmentKind.composeSubject.name,
          'edgeFeatherPx': 99.0,
          'decontamStrength': -0.5,
        },
      );
      final layer = AdjustmentLayer.fromOp(op);
      expect(layer.edgeFeatherPx, lessThanOrEqualTo(12.0));
      expect(layer.decontamStrength, greaterThanOrEqualTo(0.0));
    });
  });

  group('AdjustmentKind.composeSubject labels', () {
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
