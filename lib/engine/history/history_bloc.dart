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
            droppedCount: manager.droppedCount,
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
    on<ApplyPipelineEvent>(_onApplyPipeline);
  }

  final HistoryManager _manager;

  HistoryState _snapshot({EditPipeline? pipeline}) {
    final entries = _manager.entries;
    final cursor = _manager.cursor;
    // Surface the op types straddling the cursor so the undo/redo
    // tooltips can read "Undo Brightness" / "Redo Vignette" instead of
    // a bare "Undo".
    final lastOp =
        cursor >= 0 && cursor < entries.length ? entries[cursor].op : null;
    final nextOp =
        cursor + 1 < entries.length ? entries[cursor + 1].op : null;
    return HistoryState(
      pipeline: pipeline ?? _manager.currentPipeline,
      canUndo: _manager.canUndo,
      canRedo: _manager.canRedo,
      entryCount: _manager.entryCount,
      cursor: cursor,
      lastOpType: lastOp?.type,
      nextOpType: nextOp?.type,
      lastOpLabel: _labelFor(lastOp),
      nextOpLabel: _labelFor(nextOp),
      droppedCount: _manager.droppedCount,
    );
  }

  /// XVI.80b — extract the human-readable label for [op] when the
  /// type-string lookup would be wrong. Currently this only fires
  /// for the `preset.apply` marker added by [ApplyPipelineEvent]
  /// (used by presets + AI ops + layer ops alike), which carries
  /// the real label as `parameters['name']`. Returning null falls
  /// back to the type-based lookup in `opDisplayLabel`.
  static String? _labelFor(dynamic op) {
    if (op == null) return null;
    if (op.type != 'preset.apply') return null;
    final params = op.parameters as Map<String, Object?>?;
    final name = params?['name'];
    if (name is String && name.isNotEmpty) return name;
    return null;
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
    //
    // On release (enabled = true) we emit the committed snapshot directly
    // so the listener's identity check sees state.pipeline === manager
    // pipeline and the session clears its transient overlay. On press
    // (enabled = false) we synthesize a freshly-disabled pipeline so the
    // renderer skips every op and shows the original.
    _log.d('setAllOpsEnabled', {'enabled': event.enabled});
    if (event.enabled) {
      emit(_snapshot());
      return;
    }
    final disabled = _manager.currentPipeline.setAllEnabled(false);
    emit(_snapshot(pipeline: disabled));
  }

  Future<void> _onClear(
    ClearHistory event,
    Emitter<HistoryState> emit,
  ) async {
    await _manager.clear();
    _log.i('clear');
    emit(_snapshot());
  }

  void _onApplyPipeline(ApplyPipelineEvent event, Emitter<HistoryState> emit) {
    final marker = EditOperation.create(
      type: 'preset.apply',
      parameters: {'name': event.presetName},
    );
    _manager.execute(op: marker, newPipeline: event.pipeline);
    _log.i('applyPipeline', {
      'name': event.presetName,
      'ops': event.pipeline.operations.length,
      'cursor': _manager.cursor,
    });
    emit(_snapshot());
  }
}
