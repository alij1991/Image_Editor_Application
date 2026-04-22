import 'package:flutter_test/flutter_test.dart';

import 'package:image_editor/features/collage/application/collage_notifier.dart';
import 'package:image_editor/features/collage/domain/collage_state.dart';
import 'package:image_editor/features/collage/domain/collage_template.dart';

/// VIII.2 — per-cell zoom/pan. Pinch + drag gestures on a cell update
/// `CollageCell.transform`; transforms persist alongside images
/// across template switches and JSON round-trips.
void main() {
  group('CellTransform', () {
    test('identity defaults', () {
      const t = CellTransform.identity;
      expect(t.scale, 1.0);
      expect(t.tx, 0);
      expect(t.ty, 0);
      expect(t.isIdentity, isTrue);
    });

    test('isIdentity false when any field non-default', () {
      expect(const CellTransform(scale: 1.5).isIdentity, isFalse);
      expect(const CellTransform(tx: 0.1).isIdentity, isFalse);
      expect(const CellTransform(ty: -0.2).isIdentity, isFalse);
    });

    test('JSON omits identity fields', () {
      expect(CellTransform.identity.toJson(), <String, Object?>{});
    });

    test('JSON round-trip preserves non-default fields', () {
      const t = CellTransform(scale: 1.7, tx: 0.25, ty: -0.4);
      final restored = CellTransform.fromJson(t.toJson());
      expect(restored.scale, 1.7);
      expect(restored.tx, 0.25);
      expect(restored.ty, -0.4);
    });
  });

  group('CollageNotifier.setCellTransform', () {
    test('sets transform on a single cell + leaves others at identity', () {
      final n = CollageNotifier();
      n.setTemplate(CollageTemplates.byId('grid.2x2'));
      const t = CellTransform(scale: 1.4, tx: 0.1);
      n.setCellTransform(2, t);
      expect(n.state.cells[2].transform.scale, 1.4);
      expect(n.state.cells[2].transform.tx, 0.1);
      expect(n.state.cells[0].transform.isIdentity, isTrue);
      expect(n.state.cells[3].transform.isIdentity, isTrue);
    });

    test('out-of-bounds index is a no-op', () {
      final n = CollageNotifier();
      n.setTemplate(CollageTemplates.byId('grid.2x2'));
      n.setCellTransform(99, const CellTransform(scale: 2));
      for (final c in n.state.cells) {
        expect(c.transform.isIdentity, isTrue);
      }
    });

    test('transforms persist through template switch + restore on switch back',
        () {
      final n = CollageNotifier();
      final nine = CollageTemplates.byId('grid.3x3');
      n.setTemplate(nine);
      // Set transforms on cells 5 and 7.
      n.setCellTransform(5, const CellTransform(scale: 1.6));
      n.setCellTransform(7, const CellTransform(tx: -0.3));

      // Switch to 2x2 (only 4 cells visible) — transforms still in
      // state.cellTransforms but not visible in cells.
      n.setTemplate(CollageTemplates.byId('grid.2x2'));
      expect(n.state.cells.length, 4);
      expect(n.state.cellTransforms.length, 9,
          reason: 'transforms list must NOT shrink with template');

      // Switch back to 3x3 — transforms restored.
      n.setTemplate(nine);
      expect(n.state.cells[5].transform.scale, 1.6);
      expect(n.state.cells[7].transform.tx, -0.3);
    });
  });

  group('CollageState JSON round-trip preserves cellTransforms', () {
    test('round-trip with non-identity transforms', () {
      final original = CollageState.forTemplate(
        CollageTemplates.byId('grid.2x2'),
      ).copyWith(
        cellTransforms: const [
          CellTransform.identity,
          CellTransform(scale: 1.3, tx: 0.2),
          CellTransform.identity,
          CellTransform(ty: -0.15),
        ],
      );
      final restored = CollageState.fromJson(original.toJson());
      expect(restored.cellTransforms.length, 4);
      expect(restored.cellTransforms[1].scale, 1.3);
      expect(restored.cellTransforms[1].tx, 0.2);
      expect(restored.cellTransforms[3].ty, -0.15);
      expect(restored.cellTransforms[0].isIdentity, isTrue);
      expect(restored.cellTransforms[2].isIdentity, isTrue);
    });

    test('all-identity transforms drop the cellTransforms key entirely', () {
      final s = CollageState.forTemplate(
        CollageTemplates.byId('grid.2x2'),
      );
      expect(s.toJson().containsKey('cellTransforms'), isFalse);
    });

    test('legacy JSON without cellTransforms decodes to all identity', () {
      final legacy = {
        'templateId': 'grid.2x2',
        'imageHistory': const [null, null, null, null],
      };
      final s = CollageState.fromJson(legacy);
      expect(s.cellTransforms.length, 4);
      for (final t in s.cellTransforms) {
        expect(t.isIdentity, isTrue);
      }
    });
  });
}
