import 'package:flutter_test/flutter_test.dart';

import 'package:image_editor/engine/history/history_bloc.dart';
import 'package:image_editor/engine/history/history_event.dart';
import 'package:image_editor/engine/history/history_manager.dart';
import 'package:image_editor/engine/history/history_state.dart';
import 'package:image_editor/engine/history/memento_store.dart';
import 'package:image_editor/engine/pipeline/edit_op_type.dart';
import 'package:image_editor/engine/pipeline/edit_operation.dart';
import 'package:image_editor/engine/pipeline/edit_pipeline.dart';

/// X.B.1 — `HistoryManager._enforceHistoryLimit` used to silently drop
/// the oldest entries once the user edited past the cap (128 by
/// default). The user saw Undo targets vanish without explanation.
/// The new `droppedCount` counter + surfaced-through-HistoryState
/// field lets the timeline sheet show a banner: "N earliest edit(s)
/// dropped".
///
/// These tests pin:
///   1. Counter starts at 0.
///   2. Pre-cap execs don't increment it.
///   3. Past-cap execs increment it (one per dropped entry).
///   4. `clear()` resets it.
///   5. `HistoryState.droppedCount` propagates through the bloc.
void main() {
  EditOperation opAt(int i) => EditOperation.create(
        type: EditOpType.brightness,
        parameters: {'value': 0.01 * i},
      );

  group('HistoryManager.droppedCount', () {
    test('starts at 0', () {
      final manager = HistoryManager.withPipeline(
        mementoStore: MementoStore(),
        initial: EditPipeline.forOriginal('/tmp/x.jpg'),
        historyLimit: 3,
      );
      expect(manager.droppedCount, 0);
    });

    test('stays at 0 while entries fit under the cap', () {
      final manager = HistoryManager.withPipeline(
        mementoStore: MementoStore(),
        initial: EditPipeline.forOriginal('/tmp/x.jpg'),
        historyLimit: 5,
      );
      for (int i = 0; i < 5; i++) {
        manager.execute(
          op: opAt(i),
          newPipeline: manager.currentPipeline.append(opAt(i)),
        );
      }
      expect(manager.entryCount, 5);
      expect(manager.droppedCount, 0);
    });

    test('increments by 1 per dropped entry when the cap is exceeded', () {
      final manager = HistoryManager.withPipeline(
        mementoStore: MementoStore(),
        initial: EditPipeline.forOriginal('/tmp/x.jpg'),
        historyLimit: 3,
      );
      for (int i = 0; i < 3; i++) {
        manager.execute(
          op: opAt(i),
          newPipeline: manager.currentPipeline.append(opAt(i)),
        );
      }
      expect(manager.droppedCount, 0, reason: 'exactly at the cap');

      // The 4th push drops entry #0.
      manager.execute(
        op: opAt(3),
        newPipeline: manager.currentPipeline.append(opAt(3)),
      );
      expect(manager.entryCount, 3);
      expect(manager.droppedCount, 1);

      // Two more pushes drop the next two entries.
      manager.execute(
        op: opAt(4),
        newPipeline: manager.currentPipeline.append(opAt(4)),
      );
      manager.execute(
        op: opAt(5),
        newPipeline: manager.currentPipeline.append(opAt(5)),
      );
      expect(manager.droppedCount, 3,
          reason: 'counter is cumulative, not a snapshot');
    });

    test('clear() resets droppedCount to 0', () async {
      final manager = HistoryManager.withPipeline(
        mementoStore: MementoStore(),
        initial: EditPipeline.forOriginal('/tmp/x.jpg'),
        historyLimit: 2,
      );
      for (int i = 0; i < 5; i++) {
        manager.execute(
          op: opAt(i),
          newPipeline: manager.currentPipeline.append(opAt(i)),
        );
      }
      expect(manager.droppedCount, 3);
      await manager.clear();
      expect(manager.droppedCount, 0);
      expect(manager.entryCount, 0);
    });
  });

  group('HistoryState.droppedCount (via HistoryBloc)', () {
    test('initial state exposes droppedCount = 0', () {
      final manager = HistoryManager.withPipeline(
        mementoStore: MementoStore(),
        initial: EditPipeline.forOriginal('/tmp/x.jpg'),
        historyLimit: 2,
      );
      final bloc = HistoryBloc(manager: manager);
      addTearDown(bloc.close);
      expect(bloc.state.droppedCount, 0);
    });

    test('state reflects manager.droppedCount after pushes past the cap',
        () async {
      final manager = HistoryManager.withPipeline(
        mementoStore: MementoStore(),
        initial: EditPipeline.forOriginal('/tmp/x.jpg'),
        historyLimit: 2,
      );
      final bloc = HistoryBloc(manager: manager);
      addTearDown(bloc.close);

      bloc.add(AppendEdit(opAt(0)));
      bloc.add(AppendEdit(opAt(1)));
      bloc.add(AppendEdit(opAt(2))); // drops op 0
      bloc.add(AppendEdit(opAt(3))); // drops op 1
      await Future.delayed(Duration.zero);

      expect(bloc.state.entryCount, 2);
      expect(bloc.state.droppedCount, 2);
    });

    test('copyWith preserves droppedCount unless overridden', () {
      final a = HistoryState(
        pipeline: EditPipeline.forOriginal('/tmp/x.jpg'),
        canUndo: false,
        canRedo: false,
        entryCount: 0,
        cursor: -1,
        droppedCount: 7,
      );
      expect(a.copyWith().droppedCount, 7);
      expect(a.copyWith(droppedCount: 9).droppedCount, 9);
    });
  });
}
