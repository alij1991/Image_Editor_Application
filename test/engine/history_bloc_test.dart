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

    test('lastOpType / nextOpType track the cursor', () async {
      // After Append → lastOpType is set; nextOpType null (nothing past
      // the cursor). After Undo → lastOpType null, nextOpType points at
      // the entry we just stepped past. After Redo → swap back.
      final op = EditOperation.create(
        type: EditOpType.brightness,
        parameters: {'value': 0.4},
      );
      bloc.add(AppendEdit(op));
      await Future.delayed(Duration.zero);
      expect(bloc.state.lastOpType, EditOpType.brightness);
      expect(bloc.state.nextOpType, isNull);

      bloc.add(const UndoEdit());
      await Future.delayed(Duration.zero);
      expect(bloc.state.lastOpType, isNull);
      expect(bloc.state.nextOpType, EditOpType.brightness);

      bloc.add(const RedoEdit());
      await Future.delayed(Duration.zero);
      expect(bloc.state.lastOpType, EditOpType.brightness);
      expect(bloc.state.nextOpType, isNull);
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

    group('ApplyPipelineEvent label surfacing (XVI.80b)', () {
      test('lastOpLabel reflects the presetName, not "preset.apply"',
          () async {
        // Regression: pre-XVI.80b every ApplyPipelineEvent (used by
        // presets, AI ops, layer ops) was labelled "Preset" in the
        // undo snackbar because opDisplayLabel('preset.apply') →
        // "Preset". The label should be the human-readable
        // presetName the caller supplied — "Sharpen (AI)",
        // "Restore Faces", etc.
        final pipeline = EditPipeline.forOriginal('/tmp/img.jpg').append(
          EditOperation.create(
            type: EditOpType.brightness,
            parameters: {'value': 0.5},
          ),
        );
        bloc.add(ApplyPipelineEvent(
          pipeline: pipeline,
          presetName: 'Sharpen (AI)',
        ));
        await Future.delayed(Duration.zero);
        expect(bloc.state.lastOpType, 'preset.apply');
        expect(bloc.state.lastOpLabel, 'Sharpen (AI)');
      });

      test(
          'lastOpLabel is null when the entry is a plain non-preset op',
          () async {
        bloc.add(AppendEdit(EditOperation.create(
          type: EditOpType.brightness,
          parameters: {'value': 0.5},
        )));
        await Future.delayed(Duration.zero);
        expect(bloc.state.lastOpType, EditOpType.brightness);
        expect(bloc.state.lastOpLabel, isNull,
            reason: 'non-preset ops fall back to opDisplayLabel'
                '(lastOpType) at the call site');
      });

      test('nextOpLabel populates after undo on an ApplyPipelineEvent',
          () async {
        final pipeline = EditPipeline.forOriginal('/tmp/img.jpg').append(
          EditOperation.create(
            type: EditOpType.brightness,
            parameters: {'value': 0.5},
          ),
        );
        bloc.add(ApplyPipelineEvent(
          pipeline: pipeline,
          presetName: 'Remove background',
        ));
        await Future.delayed(Duration.zero);
        bloc.add(const UndoEdit());
        await Future.delayed(Duration.zero);
        // After undo the just-undone entry is the next redo target.
        expect(bloc.state.nextOpType, 'preset.apply');
        expect(bloc.state.nextOpLabel, 'Remove background');
      });
    });
  });
}
