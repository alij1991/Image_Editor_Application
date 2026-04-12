import 'package:equatable/equatable.dart';

/// Snapshot of a single model download's lifecycle. Emitted by
/// [ModelDownloader.download] as a `Stream<DownloadProgress>` so the
/// UI can render progress bars and handle errors.
sealed class DownloadProgress extends Equatable {
  const DownloadProgress({required this.modelId});

  final String modelId;
}

/// The downloader has been asked to fetch the model but hasn't opened
/// a connection yet (e.g. waiting for the user to confirm a Wi-Fi /
/// cellular prompt).
class DownloadQueued extends DownloadProgress {
  const DownloadQueued({required super.modelId});

  @override
  List<Object?> get props => [modelId];
}

/// Bytes are flowing. [totalBytes] may be null if the server didn't
/// return Content-Length.
class DownloadRunning extends DownloadProgress {
  const DownloadRunning({
    required super.modelId,
    required this.receivedBytes,
    required this.totalBytes,
  });

  final int receivedBytes;
  final int? totalBytes;

  /// Fractional progress in [0, 1], or null when [totalBytes] is
  /// unknown.
  double? get fraction {
    if (totalBytes == null || totalBytes! <= 0) return null;
    return receivedBytes / totalBytes!;
  }

  @override
  List<Object?> get props => [modelId, receivedBytes, totalBytes];
}

/// Download finished and the sha256 hash matched. The model file is
/// available at [localPath].
class DownloadComplete extends DownloadProgress {
  const DownloadComplete({
    required super.modelId,
    required this.localPath,
    required this.sizeBytes,
  });

  final String localPath;
  final int sizeBytes;

  @override
  List<Object?> get props => [modelId, localPath, sizeBytes];
}

/// Download failed. [stage] indicates where it failed so the UI can
/// show the right recovery action (retry, request Wi-Fi, etc.).
class DownloadFailed extends DownloadProgress {
  const DownloadFailed({
    required super.modelId,
    required this.stage,
    required this.message,
  });

  final DownloadFailureStage stage;
  final String message;

  @override
  List<Object?> get props => [modelId, stage, message];
}

enum DownloadFailureStage {
  network,
  fileSystem,
  sha256Mismatch,
  cancelled,
  unknown,
}

extension DownloadFailureStageX on DownloadFailureStage {
  String get userMessage {
    switch (this) {
      case DownloadFailureStage.network:
        return 'Network error. Check your connection and retry.';
      case DownloadFailureStage.fileSystem:
        return 'Failed to write the model file. Check available storage.';
      case DownloadFailureStage.sha256Mismatch:
        return 'Downloaded file is corrupted. Retry the download.';
      case DownloadFailureStage.cancelled:
        return 'Download cancelled.';
      case DownloadFailureStage.unknown:
        return 'Unknown error. Please try again.';
    }
  }
}
