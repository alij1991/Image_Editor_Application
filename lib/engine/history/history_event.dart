import '../pipeline/edit_operation.dart';
import '../pipeline/edit_pipeline.dart';

/// Events consumed by [HistoryBloc]. The plan calls out these five
/// canonical events; the bloc's state flow maps 1:1 with HistoryManager.
sealed class HistoryEvent {
  const HistoryEvent();
}

class ExecuteEdit extends HistoryEvent {
  const ExecuteEdit({
    required this.op,
    required this.afterParameters,
    this.beforeMementoId,
    this.afterMementoId,
  });
  final EditOperation op;
  final Map<String, dynamic> afterParameters;
  final String? beforeMementoId;
  final String? afterMementoId;
}

class AppendEdit extends HistoryEvent {
  const AppendEdit(this.op);
  final EditOperation op;
}

class UndoEdit extends HistoryEvent {
  const UndoEdit();
}

class RedoEdit extends HistoryEvent {
  const RedoEdit();
}

class ToggleOpEnabled extends HistoryEvent {
  const ToggleOpEnabled(this.opId);
  final String opId;
}

class JumpToEntry extends HistoryEvent {
  const JumpToEntry(this.index);
  final int index;
}

class SetAllOpsEnabled extends HistoryEvent {
  const SetAllOpsEnabled(this.enabled);
  final bool enabled;
}

class ClearHistory extends HistoryEvent {
  const ClearHistory();
}

/// Atomic "apply a preset" event. Records the whole [pipeline] in one
/// history entry so Undo reverts every op of the preset together.
class ApplyPresetEvent extends HistoryEvent {
  const ApplyPresetEvent({
    required this.pipeline,
    required this.presetName,
  });
  final EditPipeline pipeline;
  final String presetName;
}
