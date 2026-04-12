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
  });

  final EditPipeline pipeline;
  final bool canUndo;
  final bool canRedo;
  final int entryCount;
  final int cursor;

  HistoryState copyWith({
    EditPipeline? pipeline,
    bool? canUndo,
    bool? canRedo,
    int? entryCount,
    int? cursor,
  }) {
    return HistoryState(
      pipeline: pipeline ?? this.pipeline,
      canUndo: canUndo ?? this.canUndo,
      canRedo: canRedo ?? this.canRedo,
      entryCount: entryCount ?? this.entryCount,
      cursor: cursor ?? this.cursor,
    );
  }

  @override
  List<Object?> get props => [pipeline, canUndo, canRedo, entryCount, cursor];
}
