import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../ai/models/download_progress.dart';
import '../../../../ai/models/model_cache.dart';
import '../../../../ai/models/model_descriptor.dart';
import '../../../../ai/models/model_downloader.dart';
import '../../../../ai/models/model_manifest.dart';
import '../../../../bootstrap.dart';
import '../../../../core/feedback/user_feedback.dart';
import '../../../../core/logging/app_logger.dart';
import '../../../../core/platform/haptics.dart';
import '../../../../core/theme/spacing.dart';
import '../../../../di/providers.dart';
import 'model_manager_status.dart';

final _log = AppLogger('ModelManagerSheet');

/// Typical Wi-Fi throughput for download-time estimates — 3 MB/s is a
/// conservative mid-tier Wi-Fi reading (25 Mbps). We intentionally
/// understate so the estimate feels honest when the connection is
/// slower than expected, rather than overpromising.
const double _wifiBytesPerSecond = 3 * 1024 * 1024;

/// Typical 4G throughput — 0.25 MB/s (2 Mbps). Urban LTE is faster
/// but this is the floor we want to surface so users on cellular get
/// a time upper-bound instead of a surprise.
const double _mobileBytesPerSecond = 0.25 * 1024 * 1024;

/// Formats a size as a compact "~15 s on Wi-Fi, ~3 min on 4G" string
/// for the pre-download confirmation dialog. Extracted top-level so
/// the Phase VIII.8 test can drive it with canned sizes without
/// pumping the whole sheet.
String formatDownloadEstimates(int sizeBytes) {
  final wifi = _formatSeconds(sizeBytes / _wifiBytesPerSecond);
  final mobile = _formatSeconds(sizeBytes / _mobileBytesPerSecond);
  return '~$wifi on Wi-Fi, ~$mobile on 4G';
}

String _formatSeconds(double seconds) {
  if (seconds < 1) return '1 s';
  if (seconds < 60) return '${seconds.round()} s';
  final minutes = seconds / 60;
  if (minutes < 60) return '${minutes.round()} min';
  final hours = minutes / 60;
  return '${hours.toStringAsFixed(hours < 10 ? 1 : 0)} h';
}

/// VIII.7 — delete the partial download file for [descriptor] if one
/// exists on disk. Returns true if a file was actually removed.
/// Missing file is a no-op (returns false). Top-level so tests can
/// drive it against a real temp directory without pumping the sheet.
Future<bool> deletePartialFor(
  ModelCache cache,
  ModelDescriptor descriptor,
) async {
  try {
    final destPath = await cache.destinationPathFor(descriptor);
    final partial = File(destPath);
    if (await partial.exists()) {
      await partial.delete();
      return true;
    }
  } catch (_) {
    // Filesystem errors are non-fatal — the in-flight download is
    // already cancelled; a leftover partial just means the next
    // Download will resume. Log via the sheet's logger; swallow here
    // so the UserFeedback message stays consistent.
  }
  return false;
}

/// Lists every on-device ML model the app knows about and lets the
/// user download, delete, or retry each one. Unlike the bg removal
/// picker sheet (which is scoped to background-removal strategies),
/// this is the global "AI models" screen — surfaces everything from
/// the manifest with live cache state so the user can see
/// per-model disk usage and free space by deleting.
///
/// Status per model:
/// - **Bundled** → ships inside the app, always ready
/// - **Downloaded** → resolved from the sqflite cache
/// - **Downloadable** → manifest entry exists but no cache row yet
/// - **Downloading** → in-flight fetch with progress bar
/// - **Failed** → most recent attempt errored (with stage label)
class ModelManagerSheet extends ConsumerStatefulWidget {
  const ModelManagerSheet({super.key});

  static Future<void> show(BuildContext context) {
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (_) => const ModelManagerSheet(),
    );
  }

  @override
  ConsumerState<ModelManagerSheet> createState() =>
      _ModelManagerSheetState();
}

class _ModelManagerSheetState extends ConsumerState<ModelManagerSheet> {
  /// Cached `modelId -> ModelCacheEntry?` from the last `_load`.
  /// Null values mean "checked, not cached".
  final Map<String, ModelCacheEntry?> _cacheEntries = {};
  final Map<String, DownloadProgress> _progress = {};
  final Map<String, StreamSubscription<DownloadProgress>> _subs = {};
  bool _loading = true;
  ModelDownloader? _downloader;

  /// Phase XVI.73 — bounded download concurrency.
  ///
  /// Pre-XVI.73 the sheet started every tapped download in parallel,
  /// which on a user who taps 14 models in a row (the audit landed
  /// a bunch of new downloadables in XVI.67) buffers gigabytes of
  /// HTTP responses in memory simultaneously. Combined with an
  /// AI-op running in another part of the app (compose-on-bg loads
  /// a 244 MB BiRefNet), this OOM'd the iOS app at the 3376 MB
  /// per-process ceiling.
  ///
  /// `_maxConcurrentDownloads = 2` covers any wifi-class connection
  /// without saturating memory. Additional downloads queue up in
  /// `_pendingQueue` and are kicked off as slots free. The user
  /// can still cancel queued items via the row's Cancel button
  /// (it skips the queue entry rather than firing a no-op cancel).
  static const int _maxConcurrentDownloads = 2;
  final Set<String> _activeDownloads = {};
  final List<ModelDescriptor> _pendingQueue = [];
  final Set<String> _queuedIds = {};

  @override
  void initState() {
    super.initState();
    _downloader = ref.read(modelDownloaderProvider);
    _log.i('opened');
    _load();
  }

  @override
  void dispose() {
    // Cancel every stream subscription AND the underlying HTTP
    // request so closing the sheet doesn't leak background work.
    // NOTE: _downloader is captured in initState to avoid using
    // ref.read() in dispose() which throws after unmount.
    for (final modelId in _subs.keys.toList()) {
      _downloader?.cancel(modelId);
    }
    for (final sub in _subs.values) {
      sub.cancel();
    }
    _subs.clear();
    super.dispose();
  }

  /// Read the manifest from the bootstrap result, then query the
  /// cache for every downloadable entry so each row can show live
  /// status. Safe to call repeatedly; clears the progress map so
  /// stale "Downloaded" toasts don't persist past a manifest reload.
  Future<void> _load() async {
    final manifest = ref.read(modelManifestProvider);
    final cache = ref.read(modelCacheProvider);
    _log.i('load manifest + cache', {
      'manifestModels': manifest.descriptors.length,
    });
    final entries = <String, ModelCacheEntry?>{};
    for (final d in manifest.descriptors) {
      if (d.bundled) continue;
      try {
        entries[d.id] = await cache.get(d.id);
      } catch (e, st) {
        _log.w('cache.get failed', {'id': d.id, 'error': e.toString()});
        _log.d('cache.get stack', {'trace': st.toString()});
        entries[d.id] = null;
      }
    }
    if (!mounted) return;
    setState(() {
      _cacheEntries
        ..clear()
        ..addAll(entries);
      _loading = false;
    });
    _log.d('load complete', {
      'downloaded': entries.entries.where((e) => e.value != null).length,
      'missing': entries.entries.where((e) => e.value == null).length,
    });
  }

  /// User taps Download on a row. Confirms, then either kicks off
  /// the download immediately (if there's a free concurrency slot)
  /// or queues it. See `_maxConcurrentDownloads`.
  Future<void> _startDownload(ModelDescriptor descriptor) async {
    // XVI.121 — drop a duplicate tap on an already-active/queued model
    // BEFORE popping the confirm dialog, so a re-tap is a true no-op (it
    // previously popped the dialog again, then silently discarded the
    // result). The queued row's button is also disabled, but this guards
    // the brief downloader-side DownloadQueued window too.
    if (_activeDownloads.contains(descriptor.id) ||
        _queuedIds.contains(descriptor.id)) {
      return;
    }
    final proceed = await _confirmDownload(descriptor);
    if (proceed != true) return;
    if (!mounted) return;
    if (_activeDownloads.length >= _maxConcurrentDownloads) {
      // Queue it. Show a progress placeholder so the row reflects
      // the pending state instead of looking like the tap was lost.
      _pendingQueue.add(descriptor);
      _queuedIds.add(descriptor.id);
      setState(() {
        _progress[descriptor.id] = DownloadQueued(
          modelId: descriptor.id,
        );
      });
      _log.i('download queued', {
        'id': descriptor.id,
        'sizeBytes': descriptor.sizeBytes,
        'queueDepth': _pendingQueue.length,
        'activeDownloads': _activeDownloads.length,
      });
      Haptics.tap();
      return;
    }
    await _startDownloadNow(descriptor);
  }

  /// Drain the queue if there are free slots. Called after each
  /// download finishes (success or failure).
  void _drainQueue() {
    while (_activeDownloads.length < _maxConcurrentDownloads &&
        _pendingQueue.isNotEmpty) {
      final next = _pendingQueue.removeAt(0);
      _queuedIds.remove(next.id);
      unawaited(_startDownloadNow(next));
    }
  }

  /// Actually kick off the HTTP request for [descriptor]. Streams
  /// progress events into `_progress` so the row re-renders with a
  /// linear progress bar. On success the cache row is written and
  /// `_load()` re-runs to refresh the status chip.
  Future<void> _startDownloadNow(ModelDescriptor descriptor) async {
    if (!mounted) return;

    _activeDownloads.add(descriptor.id);
    _log.i('download start', {
      'id': descriptor.id,
      'sizeBytes': descriptor.sizeBytes,
      'activeDownloads': _activeDownloads.length,
      'queueDepth': _pendingQueue.length,
    });
    Haptics.tap();

    final downloader = ref.read(modelDownloaderProvider);
    final cache = ref.read(modelCacheProvider);
    final destPath = await cache.destinationPathFor(descriptor);
    if (!mounted) {
      _activeDownloads.remove(descriptor.id);
      return;
    }
    final stream = downloader.download(
      descriptor: descriptor,
      destinationPath: destPath,
    );
    // Replace any prior subscription for this id (retry after
    // failure) — but keep concurrent downloads for DIFFERENT ids.
    await _subs[descriptor.id]?.cancel();
    _subs[descriptor.id] = stream.listen(
      (event) async {
        if (!mounted) return;
        setState(() => _progress[descriptor.id] = event);
        if (event is DownloadComplete) {
          _log.i('download complete', {
            'id': event.modelId,
            'bytes': event.sizeBytes,
            'path': event.localPath,
          });
          try {
            await cache.put(
              ModelCacheEntry(
                modelId: event.modelId,
                version: descriptor.version,
                path: event.localPath,
                sizeBytes: event.sizeBytes,
                sha256: descriptor.sha256,
                downloadedAt: DateTime.now(),
              ),
            );
          } catch (e, st) {
            _log.e('cache.put failed',
                error: e, stackTrace: st, data: {'id': event.modelId});
          }
          if (!mounted) return;
          setState(() => _progress.remove(descriptor.id));
          _activeDownloads.remove(descriptor.id);
          Haptics.impact();
          UserFeedback.success(context,
              'Downloaded ${descriptor.id} (${descriptor.sizeDisplay})');
          await _load();
          _drainQueue();
        } else if (event is DownloadFailed) {
          _log.w('download failed', {
            'id': event.modelId,
            'stage': event.stage.name,
            'message': event.message,
          });
          if (!mounted) return;
          _activeDownloads.remove(descriptor.id);
          Haptics.warning();
          UserFeedback.error(
            context,
            'Download failed: ${event.stage.userMessage}',
            actionLabel: 'Retry',
            // Re-trigger the same flow. The state stays on the row's
            // failed badge until either the retry succeeds or the
            // user dismisses the snackbar.
            onAction: () => _startDownload(descriptor),
          );
          _drainQueue();
        }
      },
      onError: (Object e, StackTrace st) {
        _log.e('download stream error',
            error: e, stackTrace: st, data: {'id': descriptor.id});
        _activeDownloads.remove(descriptor.id);
        _drainQueue();
      },
    );
  }

  /// Cancel any in-flight download for [descriptor]. Clears the
  /// progress map so the row reverts to its cached/downloadable state.
  ///
  /// XVI.73 — also pulls the entry from the pending queue if it's
  /// waiting on a free download slot, and re-drains the queue after
  /// freeing the slot.
  void _cancelDownload(ModelDescriptor descriptor) {
    _log.i('download cancel', {'id': descriptor.id});
    // Queue-only entries don't have an active HTTP request — just
    // pop them off the queue.
    if (_queuedIds.remove(descriptor.id)) {
      _pendingQueue.removeWhere((d) => d.id == descriptor.id);
      setState(() => _progress.remove(descriptor.id));
      return;
    }
    final downloader = ref.read(modelDownloaderProvider);
    downloader.cancel(descriptor.id);
    setState(() => _progress.remove(descriptor.id));
    _activeDownloads.remove(descriptor.id);
    _drainQueue();
  }

  /// VIII.7 — cancel the in-flight download AND delete the partial file
  /// on disk. Unlike [_cancelDownload] (which leaves the partial so a
  /// later Download resumes), this path is for users who want a clean
  /// slate — e.g. the download stalled on a bad URL and they'd rather
  /// not auto-resume it.
  Future<void> _cancelAndDeleteDownload(ModelDescriptor descriptor) async {
    _log.i('download cancel+delete', {'id': descriptor.id});
    _cancelDownload(descriptor);
    final cache = ref.read(modelCacheProvider);
    final deleted = await deletePartialFor(cache, descriptor);
    if (!mounted) return;
    UserFeedback.success(
      context,
      deleted
          ? 'Cancelled and deleted partial download'
          : 'Cancelled (no partial file to delete)',
    );
  }

  /// Phase V.3: the "Free up space" button.
  ///
  /// Same eviction policy as the bootstrap low-disk guard but
  /// user-triggered — shrinks the downloaded-models disk footprint
  /// down to [_freeUpTargetBytes] by deleting the oldest entries
  /// first. Mirrors the individual-delete dialog's UX (confirm,
  /// haptic, snackbar with count). No-op (with snackbar) when the
  /// cache is already under the target.
  static const int _freeUpTargetBytes = 400 * 1024 * 1024;

  Future<void> _freeUpSpace() async {
    final currentBytes = _totalDownloadedBytes();
    if (currentBytes <= _freeUpTargetBytes) {
      if (!mounted) return;
      UserFeedback.success(
        context,
        'Cache already under '
        '${_freeUpTargetBytes ~/ (1024 * 1024)} MB — nothing to remove.',
      );
      return;
    }
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Free up space?'),
        content: const Text(
          'Deletes the oldest downloaded models until the cache is '
          'under ${_freeUpTargetBytes ~/ (1024 * 1024)} MB. Features '
          'that used the removed models will re-download on next use.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Free up'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    if (!mounted) return;
    _log.i('freeUpSpace', {'currentBytes': currentBytes});
    Haptics.impact();
    final cache = ref.read(modelCacheProvider);
    final int removed;
    try {
      removed = await cache.evictUntilUnder(_freeUpTargetBytes);
    } catch (e, st) {
      _log.e('freeUpSpace failed', error: e, stackTrace: st);
      if (!mounted) return;
      UserFeedback.error(context, 'Could not free space: $e');
      return;
    }
    if (!mounted) return;
    UserFeedback.success(
      context,
      removed == 0
          ? 'Nothing to remove.'
          : 'Freed $removed model${removed == 1 ? '' : 's'}.',
    );
    await _load();
  }

  /// Prompt then delete a cached model to free disk.
  Future<void> _deleteDownloaded(ModelDescriptor descriptor) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Delete ${descriptor.id}?'),
        content: Text(
          'This will free ${descriptor.sizeDisplay} of disk. '
          'Features that use this model will require another download '
          'before they work again.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Keep'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    if (!mounted) return;

    _log.i('delete', {'id': descriptor.id});
    Haptics.impact();
    final cache = ref.read(modelCacheProvider);
    try {
      await cache.delete(descriptor.id);
    } catch (e, st) {
      _log.e('cache.delete failed',
          error: e, stackTrace: st, data: {'id': descriptor.id});
      if (!mounted) return;
      UserFeedback.error(context, 'Could not delete ${descriptor.id}: $e');
      return;
    }
    if (!mounted) return;
    UserFeedback.success(context,
        'Deleted ${descriptor.id} (${descriptor.sizeDisplay})');
    await _load();
  }

  Future<bool?> _confirmDownload(ModelDescriptor d) async {
    final estimates = formatDownloadEstimates(d.sizeBytes);
    return showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Download ${d.id}?'),
        content: Text(
          'This will download ${d.sizeDisplay} '
          '($estimates) over your current connection. '
          'Avoid cellular if you pay for data.\n\n${d.purpose}',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Download'),
          ),
        ],
      ),
    );
  }

  ModelManagerStatus _statusFor(ModelDescriptor d) => modelManagerStatusFor(
        descriptor: d,
        progress: _progress[d.id],
        entry: _cacheEntries[d.id],
      );

  int _totalDownloadedBytes() {
    int total = 0;
    for (final entry in _cacheEntries.values) {
      if (entry != null) total += entry.sizeBytes;
    }
    return total;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final manifest = ref.watch(modelManifestProvider);
    final degradation = ref.watch(manifestDegradationProvider);
    return SizedBox(
      height: MediaQuery.sizeOf(context).height * 0.8,
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(Spacing.md),
            child: Row(
              children: [
                Icon(
                  Icons.auto_awesome_outlined,
                  color: theme.colorScheme.primary,
                ),
                const SizedBox(width: Spacing.sm),
                Text('AI models', style: theme.textTheme.titleLarge),
                const Spacer(),
                IconButton(
                  key: const Key('model-manager.free-up-space'),
                  tooltip: 'Free up space',
                  icon: const Icon(Icons.cleaning_services_outlined),
                  onPressed: _loading ? null : _freeUpSpace,
                ),
                IconButton(
                  tooltip: 'Refresh',
                  icon: const Icon(Icons.refresh),
                  onPressed: _loading ? null : _load,
                ),
                IconButton(
                  tooltip: 'Close',
                  icon: const Icon(Icons.close),
                  onPressed: () => Navigator.of(context).pop(),
                ),
              ],
            ),
          ),
          if (degradation != null) _DegradationBanner(degradation: degradation),
          const Divider(height: 1),
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : manifest.descriptors.isEmpty
                    ? _EmptyState()
                    : Builder(builder: (context) {
                        // XVI.101 — hide dormant placeholder entries
                        // (no URL + not bundled) so taps don't dead-
                        // end on "Model descriptor has no URL".
                        final visible = manifest.descriptors
                            .where((d) => d.pickerVisible)
                            .toList(growable: false);
                        if (visible.isEmpty) return _EmptyState();
                        return ListView.separated(
                          padding: const EdgeInsets.all(Spacing.md),
                          itemCount: visible.length,
                          separatorBuilder: (_, _) =>
                              const SizedBox(height: Spacing.sm),
                          itemBuilder: (context, index) {
                            final descriptor = visible[index];
                            return _ModelRow(
                              descriptor: descriptor,
                              status: _statusFor(descriptor),
                              progress: _progress[descriptor.id],
                              onDownload: () => _startDownload(descriptor),
                              onCancel: () => _cancelDownload(descriptor),
                              onCancelAndDelete: () =>
                                  _cancelAndDeleteDownload(descriptor),
                              onDelete: () => _deleteDownloaded(descriptor),
                              onRetry: () => _startDownload(descriptor),
                            );
                          },
                        );
                      }),
          ),
          if (manifest.descriptors.isNotEmpty)
            _FooterSummary(
              manifest: manifest,
              downloadedBytes: _totalDownloadedBytes(),
            ),
        ],
      ),
    );
  }
}

class _ModelRow extends StatelessWidget {
  const _ModelRow({
    required this.descriptor,
    required this.status,
    required this.progress,
    required this.onDownload,
    required this.onCancel,
    required this.onCancelAndDelete,
    required this.onDelete,
    required this.onRetry,
  });

  final ModelDescriptor descriptor;
  final ModelManagerStatus status;
  final DownloadProgress? progress;
  final VoidCallback onDownload;
  final VoidCallback onCancel;
  final VoidCallback onCancelAndDelete;
  final VoidCallback onDelete;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Material(
      color: theme.colorScheme.surfaceContainerHighest,
      borderRadius: BorderRadius.circular(12),
      child: Padding(
        padding: const EdgeInsets.all(Spacing.md),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  _iconFor(status),
                  size: 20,
                  color: _iconColorFor(status, theme),
                ),
                const SizedBox(width: Spacing.sm),
                Expanded(
                  child: Text(
                    descriptor.id,
                    style: theme.textTheme.titleSmall,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                _StatusChip(status: status),
              ],
            ),
            if (descriptor.purpose.isNotEmpty) ...[
              const SizedBox(height: Spacing.xxs),
              Text(
                descriptor.purpose,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
            const SizedBox(height: Spacing.xs),
            Wrap(
              spacing: Spacing.sm,
              runSpacing: Spacing.xxs,
              children: [
                _MetaChip(
                  icon: Icons.storage_outlined,
                  label: descriptor.sizeDisplay,
                ),
                _MetaChip(
                  icon: Icons.memory_outlined,
                  label: descriptor.runtime.name.toUpperCase(),
                ),
                _MetaChip(
                  icon: Icons.info_outline,
                  label: 'v${descriptor.version}',
                ),
              ],
            ),
            if (progress is DownloadRunning) ...[
              const SizedBox(height: Spacing.sm),
              _ProgressBar(running: progress as DownloadRunning),
            ],
            if (progress is DownloadFailed) ...[
              const SizedBox(height: Spacing.xs),
              Text(
                (progress as DownloadFailed).stage.userMessage,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.error,
                ),
              ),
            ],
            const SizedBox(height: Spacing.sm),
            Align(
              alignment: Alignment.centerRight,
              child: _buildAction(theme),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildAction(ThemeData theme) {
    switch (status) {
      case ModelManagerStatus.bundled:
        return const SizedBox.shrink();
      case ModelManagerStatus.downloaded:
        return TextButton.icon(
          icon: const Icon(Icons.delete_outline),
          label: const Text('Delete'),
          onPressed: onDelete,
        );
      case ModelManagerStatus.downloadable:
        return FilledButton.tonalIcon(
          icon: const Icon(Icons.download),
          label: const Text('Download'),
          onPressed: onDownload,
        );
      case ModelManagerStatus.queued:
        // XVI.121 — waiting for a free slot: a disabled button (so a
        // re-tap can't fire) plus a Cancel that pops it off the queue.
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            FilledButton.tonalIcon(
              icon: const Icon(Icons.schedule),
              label: const Text('Queued'),
              onPressed: null,
            ),
            const SizedBox(width: Spacing.xxs),
            TextButton.icon(
              key: const Key('model-row.cancel-queued'),
              icon: const Icon(Icons.close),
              label: const Text('Cancel'),
              onPressed: onCancel,
            ),
          ],
        );
      case ModelManagerStatus.downloading:
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextButton.icon(
              key: const Key('model-row.cancel-and-delete'),
              icon: const Icon(Icons.delete_sweep_outlined),
              label: const Text('Cancel & Delete'),
              onPressed: onCancelAndDelete,
            ),
            const SizedBox(width: Spacing.xxs),
            TextButton.icon(
              key: const Key('model-row.cancel'),
              icon: const Icon(Icons.close),
              label: const Text('Cancel'),
              onPressed: onCancel,
            ),
          ],
        );
      case ModelManagerStatus.failed:
        return FilledButton.tonalIcon(
          icon: const Icon(Icons.refresh),
          label: const Text('Retry'),
          onPressed: onRetry,
        );
      case ModelManagerStatus.outdated:
        return FilledButton.tonalIcon(
          icon: const Icon(Icons.sync),
          label: const Text('Update'),
          onPressed: onDownload,
        );
    }
  }

  IconData _iconFor(ModelManagerStatus s) {
    switch (s) {
      case ModelManagerStatus.bundled:
        return Icons.check_circle_outline;
      case ModelManagerStatus.downloaded:
        return Icons.cloud_done_outlined;
      case ModelManagerStatus.downloadable:
        return Icons.cloud_download_outlined;
      case ModelManagerStatus.queued:
        return Icons.schedule;
      case ModelManagerStatus.downloading:
        return Icons.downloading;
      case ModelManagerStatus.failed:
        return Icons.error_outline;
      case ModelManagerStatus.outdated:
        return Icons.warning_amber_outlined;
    }
  }

  Color _iconColorFor(ModelManagerStatus s, ThemeData theme) {
    switch (s) {
      case ModelManagerStatus.bundled:
      case ModelManagerStatus.downloaded:
        return theme.colorScheme.primary;
      case ModelManagerStatus.failed:
      case ModelManagerStatus.outdated:
        return theme.colorScheme.error;
      case ModelManagerStatus.downloadable:
      case ModelManagerStatus.queued:
      case ModelManagerStatus.downloading:
        return theme.colorScheme.onSurfaceVariant;
    }
  }
}

class _ProgressBar extends StatelessWidget {
  const _ProgressBar({required this.running});

  final DownloadRunning running;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        LinearProgressIndicator(value: running.fraction),
        const SizedBox(height: 4),
        Text(
          running.totalBytes == null
              ? '${running.receivedBytes ~/ 1024} KB'
              : '${running.receivedBytes ~/ 1024} / '
                  '${(running.totalBytes!) ~/ 1024} KB',
          style: theme.textTheme.bodySmall,
        ),
      ],
    );
  }
}

class _StatusChip extends StatelessWidget {
  const _StatusChip({required this.status});

  final ModelManagerStatus status;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    String label;
    Color bg;
    Color fg;
    switch (status) {
      case ModelManagerStatus.bundled:
        label = 'Bundled';
        bg = theme.colorScheme.primaryContainer;
        fg = theme.colorScheme.onPrimaryContainer;
        break;
      case ModelManagerStatus.downloaded:
        label = 'Downloaded';
        bg = theme.colorScheme.tertiaryContainer;
        fg = theme.colorScheme.onTertiaryContainer;
        break;
      case ModelManagerStatus.downloadable:
        label = 'Downloadable';
        bg = theme.colorScheme.secondaryContainer;
        fg = theme.colorScheme.onSecondaryContainer;
        break;
      case ModelManagerStatus.queued:
        label = 'Queued';
        bg = theme.colorScheme.secondaryContainer;
        fg = theme.colorScheme.onSecondaryContainer;
        break;
      case ModelManagerStatus.downloading:
        label = 'Downloading…';
        bg = theme.colorScheme.primaryContainer;
        fg = theme.colorScheme.onPrimaryContainer;
        break;
      case ModelManagerStatus.failed:
        label = 'Failed';
        bg = theme.colorScheme.errorContainer;
        fg = theme.colorScheme.onErrorContainer;
        break;
      case ModelManagerStatus.outdated:
        label = 'Outdated';
        bg = theme.colorScheme.errorContainer;
        fg = theme.colorScheme.onErrorContainer;
        break;
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Text(
        label,
        style: theme.textTheme.labelSmall?.copyWith(
          color: fg,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

class _MetaChip extends StatelessWidget {
  const _MetaChip({required this.icon, required this.label});

  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(
          icon,
          size: 12,
          color: theme.colorScheme.onSurfaceVariant,
        ),
        const SizedBox(width: 4),
        Text(
          label,
          style: theme.textTheme.labelSmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ],
    );
  }
}

class _FooterSummary extends StatelessWidget {
  const _FooterSummary({
    required this.manifest,
    required this.downloadedBytes,
  });

  final ModelManifest manifest;
  final int downloadedBytes;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final bundled = manifest.bundled.length;
    final downloadable = manifest.downloadable.length;
    final manifestBytes = manifest.descriptors.fold<int>(
      0,
      (sum, d) => sum + d.sizeBytes,
    );
    final manifestMb = (manifestBytes / (1024 * 1024)).toStringAsFixed(0);
    final downloadedMb = (downloadedBytes / (1024 * 1024)).toStringAsFixed(1);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(Spacing.md),
      color: theme.colorScheme.surface,
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              '$bundled bundled · $downloadable downloadable · '
              '$manifestMb MB total',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 2),
            Text(
              'Downloaded so far: $downloadedMb MB',
              textAlign: TextAlign.center,
              style: theme.textTheme.labelSmall?.copyWith(
                color: theme.colorScheme.primary,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(Spacing.xl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.inventory_2_outlined,
              size: 48,
              color: theme.colorScheme.onSurfaceVariant,
            ),
            const SizedBox(height: Spacing.md),
            Text(
              'No models in manifest',
              style: theme.textTheme.titleSmall,
            ),
            const SizedBox(height: Spacing.xs),
            Text(
              'The manifest file is missing or could not be read.',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Top-of-sheet banner surfaced when the bootstrap's manifest load
/// failed or returned empty. Shown so the user learns something's
/// wrong BEFORE they tap an AI feature that silently does nothing —
/// Phase I.10's motivation.
///
/// Non-dismissible — the condition is persistent (the manifest
/// doesn't change between app launches without a reinstall), so
/// there's nothing to dismiss. Rendered with warning colours from
/// the Material 3 error container scheme to differentiate from
/// normal content.
class _DegradationBanner extends StatelessWidget {
  const _DegradationBanner({required this.degradation});
  final BootstrapDegradation degradation;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      key: const Key('model-manager.degradation-banner'),
      width: double.infinity,
      color: theme.colorScheme.errorContainer,
      padding: const EdgeInsets.symmetric(
        horizontal: Spacing.md,
        vertical: Spacing.sm,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            Icons.warning_amber_outlined,
            color: theme.colorScheme.onErrorContainer,
          ),
          const SizedBox(width: Spacing.sm),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'AI features are unavailable',
                  style: theme.textTheme.titleSmall?.copyWith(
                    color: theme.colorScheme.onErrorContainer,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  degradation.message,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onErrorContainer,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
