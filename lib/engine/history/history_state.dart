import 'package:equatable/equatable.dart';

import '../pipeline/edit_pipeline.dart';

/// Snapshot of the history subsystem. The [HistoryBloc] emits a new one on
/// every mutation. [pipeline] is always the current applied pipeline that
/// the preview renderer should render.
class HistoryState extends Equatable {
  const HistoryState({
    required this.pipeline,
    required this.canUndo,
    required this.canRedo,
    required this.entryCount,
    required this.cursor,
    this.lastOpType,
    this.nextOpType,
    this.droppedCount = 0,
  });

  final EditPipeline pipeline;
  final bool canUndo;
  final bool canRedo;
  final int entryCount;
  final int cursor;

  /// Type string (e.g. `color.brightness`) of the op that the *next*
  /// undo would revert. Null when there's nothing to undo. Surface in
  /// the UI as a tooltip ("Undo Brightness") so the user knows what
  /// they're about to lose.
  final String? lastOpType;

  /// Type string of the op that the *next* redo would re-apply, or
  /// null when redo isn't available.
  final String? nextOpType;

  /// Phase X.B.1 — cumulative number of oldest entries silently
  /// evicted by `HistoryManager._enforceHistoryLimit` since the last
  /// `clear()`. Non-zero ⇒ the user hit the cap and lost Undo
  /// targets they can't recover. The history timeline sheet surfaces
  /// this as a banner so the truncation is visible instead of silent.
  final int droppedCount;

  HistoryState copyWith({
    EditPipeline? pipeline,
    bool? canUndo,
    bool? canRedo,
    int? entryCount,
    int? cursor,
    String? lastOpType,
    String? nextOpType,
    int? droppedCount,
  }) {
    return HistoryState(
      pipeline: pipeline ?? this.pipeline,
      canUndo: canUndo ?? this.canUndo,
      canRedo: canRedo ?? this.canRedo,
      entryCount: entryCount ?? this.entryCount,
      cursor: cursor ?? this.cursor,
      lastOpType: lastOpType ?? this.lastOpType,
      nextOpType: nextOpType ?? this.nextOpType,
      droppedCount: droppedCount ?? this.droppedCount,
    );
  }

  @override
  List<Object?> get props => [
        pipeline,
        canUndo,
        canRedo,
        entryCount,
        cursor,
        lastOpType,
        nextOpType,
        droppedCount,
      ];
}
