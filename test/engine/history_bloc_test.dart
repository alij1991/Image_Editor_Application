import 'package:flutter_test/flutter_test.dart';

import 'package:image_editor/engine/history/history_bloc.dart';
import 'package:image_editor/engine/history/history_event.dart';
import 'package:image_editor/engine/history/history_manager.dart';
import 'package:image_editor/engine/history/memento_store.dart';
import 'package:image_editor/engine/pipeline/edit_op_type.dart';
import 'package:image_editor/engine/pipeline/edit_operation.dart';
import 'package:image_editor/engine/pipeline/edit_pipeline.dart';

void main() {
  group('HistoryBloc', () {
    late HistoryBloc bloc;

    setUp(() {
      final manager = HistoryManager.withPipeline(
        mementoStore: MementoStore(),
        initial: EditPipeline.forOriginal('/tmp/img.jpg'),
      );
      bloc = HistoryBloc(manager: manager);
    });

    tearDown(() async {
      await bloc.close();
    });

    test('initial state is empty pipeline with no undo/redo', () {
      expect(bloc.state.pipeline.operations, isEmpty);
      expect(bloc.state.canUndo, false);
      expect(bloc.state.canRedo, false);
    });

    test('AppendEdit pushes op into pipeline', () async {
      final op = EditOperation.create(
        type: EditOpType.brightness,
        parameters: {'value': 0.3},
      );
      bloc.add(AppendEdit(op));
      await Future.delayed(Duration.zero);
      expect(bloc.state.pipeline.operations.length, 1);
      expect(bloc.state.canUndo, true);
    });

    test('UndoEdit + RedoEdit round trip', () async {
      final op = EditOperation.create(
        type: EditOpType.contrast,
        parameters: {'value': 0.2},
      );
      bloc
        ..add(AppendEdit(op))
        ..add(const UndoEdit());
      await Future.delayed(Duration.zero);
      expect(bloc.state.pipeline.operations, isEmpty);
      bloc.add(const RedoEdit());
      await Future.delayed(Duration.zero);
      expect(bloc.state.pipeline.operations.length, 1);
    });

    test('SetAllOpsEnabled emits a transient state and does not record history',
        () async {
      final op = EditOperation.create(
        type: EditOpType.brightness,
        parameters: {'value': 0.5},
      );
      bloc.add(AppendEdit(op));
      await Future.delayed(Duration.zero);
      final entriesBefore = bloc.state.entryCount;

      bloc.add(const SetAllOpsEnabled(false));
      await Future.delayed(Duration.zero);
      expect(bloc.state.pipeline.activeCount, 0);
      expect(bloc.state.entryCount, entriesBefore,
          reason: 'tap-hold must not record a history entry');
    });

    test('SetAllOpsEnabled press emits non-identical pipeline; release emits committed',
        () async {
      // The press/release dance is what powers the press-and-hold compare:
      // the listener uses identity to detect the transient overlay. Pressing
      // must produce a fresh pipeline (so the listener routes to the
      // transient path); releasing must emit the committed pipeline
      // (identical to the manager's, so the listener clears its overlay).
      final op = EditOperation.create(
        type: EditOpType.brightness,
        parameters: {'value': 0.5},
      );
      bloc.add(AppendEdit(op));
      await Future.delayed(Duration.zero);
      final committedAfterAppend = bloc.state.pipeline;

      bloc.add(const SetAllOpsEnabled(false));
      await Future.delayed(Duration.zero);
      expect(identical(bloc.state.pipeline, committedAfterAppend), false,
          reason: 'press must emit a transient pipeline distinct from committed');
      expect(bloc.state.pipeline.activeCount, 0);

      bloc.add(const SetAllOpsEnabled(true));
      await Future.delayed(Duration.zero);
      expect(identical(bloc.state.pipeline, committedAfterAppend), true,
          reason: 'release must emit the committed pipeline so the listener '
              'clears its transient overlay');
      expect(bloc.state.pipeline.activeCount, 1);
    });
  });
}
