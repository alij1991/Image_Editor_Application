import 'package:flutter_bloc/flutter_bloc.dart';

import '../../core/logging/app_logger.dart';
import '../pipeline/edit_operation.dart';
import '../pipeline/edit_pipeline.dart';
import 'history_event.dart';
import 'history_manager.dart';
import 'history_state.dart';

final _log = AppLogger('HistoryBloc');

/// Bloc wrapper around [HistoryManager]. The plan specifies Bloc for the
/// history subsystem because its explicit Event -> State flow maps
/// cleanly to Command + Memento semantics.
class HistoryBloc extends Bloc<HistoryEvent, HistoryState> {
  HistoryBloc({required HistoryManager manager})
      : _manager = manager,
        super(
          HistoryState(
            pipeline: manager.currentPipeline,
            canUndo: manager.canUndo,
            canRedo: manager.canRedo,
            entryCount: manager.entryCount,
            cursor: manager.cursor,
          ),
        ) {
    on<ExecuteEdit>(_onExecute);
    on<AppendEdit>(_onAppend);
    on<UndoEdit>(_onUndo);
    on<RedoEdit>(_onRedo);
    on<ToggleOpEnabled>(_onToggle);
    on<JumpToEntry>(_onJump);
    on<SetAllOpsEnabled>(_onSetAll);
    on<ClearHistory>(_onClear);
    on<ApplyPresetEvent>(_onApplyPreset);
  }

  final HistoryManager _manager;

  HistoryState _snapshot({EditPipeline? pipeline}) {
    return HistoryState(
      pipeline: pipeline ?? _manager.currentPipeline,
      canUndo: _manager.canUndo,
      canRedo: _manager.canRedo,
      entryCount: _manager.entryCount,
      cursor: _manager.cursor,
    );
  }

  void _onExecute(ExecuteEdit event, Emitter<HistoryState> emit) {
    final updated = event.op.copyWith(parameters: event.afterParameters);
    final currentHas = _manager.currentPipeline.operations
        .any((o) => o.id == updated.id);
    final nextPipeline = currentHas
        ? _manager.currentPipeline.replace(updated)
        : _manager.currentPipeline.append(updated);
    _manager.execute(
      op: updated,
      newPipeline: nextPipeline,
      beforeMementoId: event.beforeMementoId,
      afterMementoId: event.afterMementoId,
    );
    _log.i('execute', {
      'type': updated.type,
      'action': currentHas ? 'replace' : 'append',
      'params': updated.parameters,
      'cursor': _manager.cursor,
    });
    emit(_snapshot());
  }

  void _onAppend(AppendEdit event, Emitter<HistoryState> emit) {
    final nextPipeline = _manager.currentPipeline.append(event.op);
    _manager.execute(op: event.op, newPipeline: nextPipeline);
    _log.i('append', {
      'type': event.op.type,
      'params': event.op.parameters,
      'cursor': _manager.cursor,
    });
    emit(_snapshot());
  }

  void _onUndo(UndoEdit event, Emitter<HistoryState> emit) {
    if (_manager.undo()) {
      _log.i('undo', {
        'cursor': _manager.cursor,
        'ops': _manager.currentPipeline.operations.length,
      });
      emit(_snapshot());
    } else {
      _log.d('undo skipped (nothing to undo)');
    }
  }

  void _onRedo(RedoEdit event, Emitter<HistoryState> emit) {
    if (_manager.redo()) {
      _log.i('redo', {
        'cursor': _manager.cursor,
        'ops': _manager.currentPipeline.operations.length,
      });
      emit(_snapshot());
    } else {
      _log.d('redo skipped (nothing to redo)');
    }
  }

  void _onToggle(ToggleOpEnabled event, Emitter<HistoryState> emit) {
    _manager.toggleEnabled(event.opId);
    _log.i('toggle op enabled', {'opId': event.opId});
    emit(_snapshot());
  }

  void _onJump(JumpToEntry event, Emitter<HistoryState> emit) {
    _manager.jumpTo(event.index);
    _log.i('jumpTo', {'index': event.index});
    emit(_snapshot());
  }

  void _onSetAll(SetAllOpsEnabled event, Emitter<HistoryState> emit) {
    // Setting all ops enabled/disabled is the before/after tap-hold.
    // We do NOT record this as a history entry — it's a transient view.
    final nextPipeline = _manager.currentPipeline.setAllEnabled(event.enabled);
    _log.d('setAllOpsEnabled', {'enabled': event.enabled});
    emit(_snapshot(pipeline: nextPipeline));
  }

  Future<void> _onClear(
    ClearHistory event,
    Emitter<HistoryState> emit,
  ) async {
    await _manager.clear();
    _log.i('clear');
    emit(_snapshot());
  }

  void _onApplyPreset(ApplyPresetEvent event, Emitter<HistoryState> emit) {
    final marker = EditOperation.create(
      type: 'preset.apply',
      parameters: {'name': event.presetName},
    );
    _manager.execute(op: marker, newPipeline: event.pipeline);
    _log.i('applyPreset', {
      'name': event.presetName,
      'ops': event.pipeline.operations.length,
      'cursor': _manager.cursor,
    });
    emit(_snapshot());
  }
}
