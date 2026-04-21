import 'package:flutter_test/flutter_test.dart';

import 'package:image_editor/features/collage/application/collage_notifier.dart';
import 'package:image_editor/features/collage/domain/collage_template.dart';

/// Unit tests for [CollageNotifier] state-mutation semantics.
///
/// Focus is the image-preservation contract: switching to a smaller
/// template keeps the dropped paths around for the rest of the
/// session, and switching back restores them. Covers `setTemplate`,
/// `setCellImage`, `swapCellImages`, and `reset`.
///
/// No [CollageRepository] is injected — persistence is out of scope
/// for this file. See `collage_repository_test.dart` for disk round-
/// trip coverage.
void main() {
  group('CollageNotifier setTemplate preservation', () {
    test('switching to a smaller template keeps dropped paths in history',
        () {
      final n = CollageNotifier();
      final template9 = CollageTemplates.byId('grid.3x3');
      n.setTemplate(template9);

      // Populate all 9 cells.
      for (var i = 0; i < 9; i++) {
        n.setCellImage(i, '/tmp/$i.jpg');
      }
      expect(n.state.imageHistory.length, 9);
      for (var i = 0; i < 9; i++) {
        expect(n.state.imageHistory[i], '/tmp/$i.jpg');
      }

      // Switch to 2×2 — cells becomes 4, but history still holds all 9.
      n.setTemplate(CollageTemplates.byId('grid.2x2'));
      expect(n.state.cells.length, 4);
      expect(n.state.imageHistory.length, 9,
          reason: 'history must NOT shrink when the template does');
      expect(n.state.cells[0].imagePath, '/tmp/0.jpg');
      expect(n.state.cells[3].imagePath, '/tmp/3.jpg');
    });

    test('switching back to a larger template restores preserved paths',
        () {
      final n = CollageNotifier();
      final nine = CollageTemplates.byId('grid.3x3');
      n.setTemplate(nine);
      for (var i = 0; i < 9; i++) {
        n.setCellImage(i, '/tmp/$i.jpg');
      }

      n.setTemplate(CollageTemplates.byId('grid.2x2'));
      n.setTemplate(nine);

      expect(n.state.cells.length, 9);
      for (var i = 0; i < 9; i++) {
        expect(n.state.cells[i].imagePath, '/tmp/$i.jpg',
            reason: 'cell $i should restore from history');
      }
    });

    test('switching from small → large grows history with nulls', () {
      final n = CollageNotifier();
      // Default first template has 2 cells (grid.1x2). Tag them.
      final first = CollageTemplates.all.first;
      expect(first.cells.length, 2, reason: 'first template sanity');
      n.setCellImage(0, '/tmp/a.jpg');
      n.setCellImage(1, '/tmp/b.jpg');
      expect(n.state.imageHistory, ['/tmp/a.jpg', '/tmp/b.jpg']);

      n.setTemplate(CollageTemplates.byId('grid.3x3'));
      expect(n.state.imageHistory.length, 9);
      // First two entries survive; the rest are null (never picked).
      expect(n.state.imageHistory[0], '/tmp/a.jpg');
      expect(n.state.imageHistory[1], '/tmp/b.jpg');
      for (var i = 2; i < 9; i++) {
        expect(n.state.imageHistory[i], isNull);
      }
    });

    test('picking an image in a smaller template then growing preserves it',
        () {
      final n = CollageNotifier();
      n.setTemplate(CollageTemplates.byId('grid.2x2'));
      n.setCellImage(2, '/tmp/inner.jpg');
      n.setTemplate(CollageTemplates.byId('grid.3x3'));
      expect(n.state.cells[2].imagePath, '/tmp/inner.jpg');
    });
  });

  group('CollageNotifier setCellImage', () {
    test('clearing a slot (null) removes it from history', () {
      final n = CollageNotifier();
      n.setTemplate(CollageTemplates.byId('grid.2x2'));
      n.setCellImage(0, '/tmp/a.jpg');
      n.setCellImage(0, null);
      expect(n.state.imageHistory[0], isNull);
      expect(n.state.cells[0].imagePath, isNull);
    });

    test('out-of-range indices are no-ops', () {
      final n = CollageNotifier();
      n.setTemplate(CollageTemplates.byId('grid.2x2'));
      final before = n.state.imageHistory;
      n.setCellImage(-1, '/tmp/wrong.jpg');
      n.setCellImage(99, '/tmp/wrong.jpg');
      expect(n.state.imageHistory, before);
    });

    test('setting the same slot twice overwrites the prior path', () {
      final n = CollageNotifier();
      n.setTemplate(CollageTemplates.byId('grid.2x2'));
      n.setCellImage(1, '/tmp/first.jpg');
      n.setCellImage(1, '/tmp/second.jpg');
      expect(n.state.imageHistory[1], '/tmp/second.jpg');
    });
  });

  group('CollageNotifier swapCellImages', () {
    test('swaps paths in history + on display', () {
      final n = CollageNotifier();
      n.setTemplate(CollageTemplates.byId('grid.2x2'));
      n.setCellImage(0, '/tmp/A.jpg');
      n.setCellImage(3, '/tmp/D.jpg');
      n.swapCellImages(0, 3);
      expect(n.state.cells[0].imagePath, '/tmp/D.jpg');
      expect(n.state.cells[3].imagePath, '/tmp/A.jpg');
      expect(n.state.imageHistory[0], '/tmp/D.jpg');
      expect(n.state.imageHistory[3], '/tmp/A.jpg');
    });

    test('swap within smaller template preserves when growing back', () {
      final n = CollageNotifier();
      final nine = CollageTemplates.byId('grid.3x3');
      n.setTemplate(nine);
      for (var i = 0; i < 9; i++) {
        n.setCellImage(i, '/tmp/$i.jpg');
      }
      // Shrink, swap the first two visible cells, then grow back.
      n.setTemplate(CollageTemplates.byId('grid.2x2'));
      n.swapCellImages(0, 1);
      n.setTemplate(nine);
      expect(n.state.cells[0].imagePath, '/tmp/1.jpg');
      expect(n.state.cells[1].imagePath, '/tmp/0.jpg');
      // The un-swapped 3×3 tail is untouched.
      expect(n.state.cells[4].imagePath, '/tmp/4.jpg');
    });

    test('no-op swap (a == b) leaves history unchanged', () {
      final n = CollageNotifier();
      n.setTemplate(CollageTemplates.byId('grid.2x2'));
      n.setCellImage(2, '/tmp/x.jpg');
      final before = n.state.imageHistory;
      n.swapCellImages(2, 2);
      expect(n.state.imageHistory, before);
    });
  });

  group('CollageNotifier reset', () {
    test('clears history and returns to the first template', () {
      final n = CollageNotifier();
      n.setTemplate(CollageTemplates.byId('grid.3x3'));
      for (var i = 0; i < 9; i++) {
        n.setCellImage(i, '/tmp/$i.jpg');
      }
      n.reset();
      expect(n.state.template.id, CollageTemplates.all.first.id);
      expect(
        n.state.imageHistory.every((p) => p == null),
        true,
        reason: 'every history entry must be null after reset',
      );
    });
  });

  group('CollageNotifier initial state', () {
    test('starts on the first template with a null history matching size',
        () {
      final n = CollageNotifier();
      final first = CollageTemplates.all.first;
      expect(n.state.template.id, first.id);
      expect(n.state.imageHistory.length, first.cells.length);
      expect(n.state.imageHistory.every((p) => p == null), true);
    });
  });

  group('CollageNotifier same-template no-op', () {
    test('setTemplate with the current template does not mutate state', () {
      final n = CollageNotifier();
      final before = n.state;
      n.setTemplate(n.state.template);
      expect(identical(n.state, before), true,
          reason: 'same-template setTemplate should be a no-op');
    });
  });
}
