import 'package:image_editor/ai/models/download_progress.dart';
import 'package:image_editor/ai/models/model_cache.dart';
import 'package:image_editor/ai/models/model_descriptor.dart';

/// Per-model render state for the Model Manager row — drives the chip
/// colour, icon, and action button. Kept deliberately separate from
/// [ModelRuntime] / [ResolvedKind] so UI-only states don't bleed into
/// the core model layer.
///
/// Extracted from `model_manager_sheet.dart` (XVI.121) together with
/// [modelManagerStatusFor] so the mapping is unit-testable without
/// pumping the sheet.
enum ModelManagerStatus {
  bundled,
  downloaded,
  downloadable,

  /// Waiting for a concurrency slot (see the sheet's `_pendingQueue`),
  /// or the brief window before a started download emits its first
  /// running tick. XVI.121 — before this existed a queued model fell
  /// through to [downloadable] and rendered a live Download button that
  /// swallowed re-taps.
  queued,
  downloading,
  failed,
  outdated,
}

/// Pure mapping from a model's descriptor + its current download
/// progress + its cache entry to the row's render state.
///
/// Order matters: an in-flight [DownloadProgress] (queued / running /
/// failed) wins over the on-disk facts, so a model the user just queued
/// shows "Queued" rather than its pre-download state.
ModelManagerStatus modelManagerStatusFor({
  required ModelDescriptor descriptor,
  required DownloadProgress? progress,
  required ModelCacheEntry? entry,
}) {
  if (progress is DownloadQueued) return ModelManagerStatus.queued;
  if (progress is DownloadRunning) return ModelManagerStatus.downloading;
  if (progress is DownloadFailed) return ModelManagerStatus.failed;
  if (descriptor.bundled) return ModelManagerStatus.bundled;
  if (entry == null) return ModelManagerStatus.downloadable;
  if (entry.version != descriptor.version) return ModelManagerStatus.outdated;
  return ModelManagerStatus.downloaded;
}
