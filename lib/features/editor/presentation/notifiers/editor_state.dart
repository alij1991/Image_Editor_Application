import 'package:equatable/equatable.dart';

import 'editor_session.dart';

/// State of the root editor notifier. A session is either idle (no image
/// loaded) or active with a live [EditorSession].
sealed class EditorState extends Equatable {
  const EditorState();

  @override
  List<Object?> get props => [];
}

class EditorIdle extends EditorState {
  const EditorIdle();
}

class EditorLoading extends EditorState {
  const EditorLoading({required this.sourcePath});
  final String sourcePath;

  @override
  List<Object?> get props => [sourcePath];
}

class EditorReady extends EditorState {
  const EditorReady({required this.session});
  final EditorSession session;

  @override
  List<Object?> get props => [session];
}

class EditorError extends EditorState {
  const EditorError({required this.message, this.cause});
  final String message;
  final Object? cause;

  @override
  List<Object?> get props => [message, cause];
}
