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

/// Atomic pipeline-replace event. Records the whole [pipeline] in one
/// history entry so Undo reverts every change together.
///
/// Used for preset application, layer additions/deletions/reorders, and
/// any other operation that replaces the full pipeline atomically. The
/// [presetName] field is a human-readable label shown in the history
/// timeline — it is NOT required to match an actual [Preset].
class ApplyPipelineEvent extends HistoryEvent {
  const ApplyPipelineEvent({
    required this.pipeline,
    required this.presetName,
  });
  final EditPipeline pipeline;
  final String presetName;
}
