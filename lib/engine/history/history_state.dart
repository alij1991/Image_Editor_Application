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

  HistoryState copyWith({
    EditPipeline? pipeline,
    bool? canUndo,
    bool? canRedo,
    int? entryCount,
    int? cursor,
    String? lastOpType,
    String? nextOpType,
  }) {
    return HistoryState(
      pipeline: pipeline ?? this.pipeline,
      canUndo: canUndo ?? this.canUndo,
      canRedo: canRedo ?? this.canRedo,
      entryCount: entryCount ?? this.entryCount,
      cursor: cursor ?? this.cursor,
      lastOpType: lastOpType ?? this.lastOpType,
      nextOpType: nextOpType ?? this.nextOpType,
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
      ];
}
