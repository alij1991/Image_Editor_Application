import 'package:flutter_test/flutter_test.dart';

import 'package:image_editor/engine/history/history_manager.dart';
import 'package:image_editor/engine/history/memento_store.dart';
import 'package:image_editor/engine/pipeline/edit_op_type.dart';
import 'package:image_editor/engine/pipeline/edit_operation.dart';
import 'package:image_editor/engine/pipeline/edit_pipeline.dart';

void main() {
  group('HistoryManager', () {
    late HistoryManager manager;

    setUp(() {
      manager = HistoryManager.withPipeline(
        mementoStore: MementoStore(),
        initial: EditPipeline.forOriginal('/tmp/img.jpg'),
      );
    });

    test('empty history has nothing to undo or redo', () {
      expect(manager.canUndo, false);
      expect(manager.canRedo, false);
      expect(manager.entryCount, 0);
    });

    test('execute records an entry and pushes current forward', () {
      final op = EditOperation.create(
        type: EditOpType.brightness,
        parameters: {'value': 0.2},
      );
      manager.execute(
        op: op,
        newPipeline: manager.currentPipeline.append(op),
      );
      expect(manager.entryCount, 1);
      expect(manager.canUndo, true);
      expect(manager.canRedo, false);
      expect(manager.currentPipeline.operations.first.id, op.id);
    });

    test('undo restores previous pipeline', () {
      final op1 = EditOperation.create(
        type: EditOpType.brightness,
        parameters: {'value': 0.1},
      );
      final op2 = EditOperation.create(
        type: EditOpType.contrast,
        parameters: {'value': 0.2},
      );

      final afterOne = manager.currentPipeline.append(op1);
      manager.execute(op: op1, newPipeline: afterOne);
      final afterTwo = afterOne.append(op2);
      manager.execute(op: op2, newPipeline: afterTwo);

      expect(manager.currentPipeline.operations.length, 2);
      manager.undo();
      expect(manager.currentPipeline.operations.length, 1);
      expect(manager.currentPipeline.operations.first.id, op1.id);
      manager.undo();
      expect(manager.currentPipeline.operations.length, 0);
      expect(manager.canUndo, false);
      expect(manager.canRedo, true);
    });

    test('redo reapplies', () {
      final op = EditOperation.create(
        type: EditOpType.brightness,
        parameters: {'value': 0.3},
      );
      manager.execute(
        op: op,
        newPipeline: manager.currentPipeline.append(op),
      );
      manager.undo();
      expect(manager.currentPipeline.operations.length, 0);
      manager.redo();
      expect(manager.currentPipeline.operations.length, 1);
      expect(manager.currentPipeline.operations.first.id, op.id);
    });

    test('new execute truncates redo tail', () {
      final op1 = EditOperation.create(
        type: EditOpType.brightness,
        parameters: {'value': 0.1},
      );
      final op2 = EditOperation.create(
        type: EditOpType.contrast,
        parameters: {'value': 0.2},
      );
      final op3 = EditOperation.create(
        type: EditOpType.saturation,
        parameters: {'value': -0.2},
      );

      manager.execute(op: op1, newPipeline: manager.currentPipeline.append(op1));
      manager.execute(op: op2, newPipeline: manager.currentPipeline.append(op2));
      manager.undo(); // back to op1
      manager.execute(op: op3, newPipeline: manager.currentPipeline.append(op3));
      expect(manager.canRedo, false);
      expect(manager.entryCount, 2);
      expect(manager.currentPipeline.operations.map((o) => o.id).toList(),
          [op1.id, op3.id]);
    });

    test('jumpTo replays to a specific entry', () {
      final ops = [
        for (int i = 0; i < 5; i++)
          EditOperation.create(
            type: EditOpType.brightness,
            parameters: {'value': 0.1 * i},
          ),
      ];
      for (final op in ops) {
        manager.execute(
          op: op,
          newPipeline: manager.currentPipeline.append(op),
        );
      }
      manager.jumpTo(2);
      expect(manager.currentPipeline.operations.length, 3);
      expect(manager.currentPipeline.operations.last.id, ops[2].id);
      manager.jumpTo(-1);
      expect(manager.currentPipeline.operations.length, 0);
    });
  });
}
