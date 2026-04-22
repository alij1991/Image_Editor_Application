import 'dart:async';

import 'package:flutter/material.dart';

import '../../../../ai/models/download_progress.dart';
import '../../../../ai/models/model_cache.dart';
import '../../../../ai/models/model_descriptor.dart';
import '../../../../ai/models/model_downloader.dart';
import '../../../../ai/models/model_registry.dart';
import '../../../../ai/services/bg_removal/bg_removal_factory.dart';
import '../../../../ai/services/bg_removal/bg_removal_strategy.dart';
import '../../../../core/feedback/user_feedback.dart';
import '../../../../core/logging/app_logger.dart';
import '../../../../core/platform/haptics.dart';
import '../../../../core/theme/spacing.dart';

final _log = AppLogger('BgRemovalPickerSheet');

/// Modal bottom sheet that lists every background-removal strategy
/// with its current availability, and lets the user pick one.
///
/// For strategies that need a downloaded model, the sheet embeds a
/// download button + progress bar so the user can fetch the model
/// without leaving the editor. Once ready, the sheet pops with the
/// selected [BgRemovalStrategyKind] so the caller can build and run
/// the strategy.
class BgRemovalPickerSheet extends StatefulWidget {
  const BgRemovalPickerSheet({
    required this.factory,
    required this.registry,
    required this.downloader,
    super.key,
  });

  final BgRemovalFactory factory;
  final ModelRegistry registry;
  final ModelDownloader downloader;

  static Future<BgRemovalStrategyKind?> show(
    BuildContext context, {
    required BgRemovalFactory factory,
    required ModelRegistry registry,
    required ModelDownloader downloader,
  }) {
    return showModalBottomSheet<BgRemovalStrategyKind>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (_) => BgRemovalPickerSheet(
        factory: factory,
        registry: registry,
        downloader: downloader,
      ),
    );
  }

  @override
  State<BgRemovalPickerSheet> createState() => _BgRemovalPickerSheetState();
}

class _BgRemovalPickerSheetState extends State<BgRemovalPickerSheet> {
  final Map<BgRemovalStrategyKind, BgRemovalAvailability> _availability = {};
  final Map<BgRemovalStrategyKind, DownloadProgress> _progress = {};
  final Set<BgRemovalStrategyKind> _loadingAvailability = {};
  StreamSubscription<DownloadProgress>? _activeSub;
  BgRemovalStrategyKind? _activeDownloadKind;

  @override
  void initState() {
    super.initState();
    // Snapshot every strategy's manifest descriptor state so the log
    // records what the picker *opened against* (useful when a user
    // reports "the picker showed the wrong option" — tells us what
    // the manifest+registry state looked like at open time).
    final openState = <String, Object?>{};
    for (final kind in BgRemovalStrategyKind.values) {
      final modelId = kind.modelId;
      if (modelId == null) {
        openState[kind.name] = 'bundled';
      } else {
        final descriptor = widget.registry.descriptor(modelId);
        openState[kind.name] =
            descriptor == null ? 'missing-from-manifest' : modelId;
      }
    }
    _log.i('opened', openState);
    _refreshAll();
  }

  @override
  void dispose() {
    // Cancel any in-flight download + drop the stream subscription
    // so the downloader doesn't keep writing bytes after the user
    // dismissed the sheet. Safe even if no download is active.
    final active = _activeDownloadKind;
    if (active != null) {
      final modelId = active.modelId;
      if (modelId != null) {
        widget.downloader.cancel(modelId);
      }
    }
    _activeSub?.cancel();
    super.dispose();
  }

  Future<void> _refreshAll() async {
    for (final kind in BgRemovalStrategyKind.values) {
      if (!mounted) return;
      setState(() => _loadingAvailability.add(kind));
      final a = await widget.factory.availability(kind);
      if (!mounted) return;
      setState(() {
        _availability[kind] = a;
        _loadingAvailability.remove(kind);
      });
      _log.d('availability', {'kind': kind.name, 'state': a.name});
    }
  }

  Future<void> _startDownload(BgRemovalStrategyKind kind) async {
    final modelId = kind.modelId;
    if (modelId == null) return;
    final descriptor = widget.registry.descriptor(modelId);
    if (descriptor == null) {
      UserFeedback.error(context,
          'Model "$modelId" is missing from the manifest.');
      return;
    }
    // Warn the user before downloading a large file over any connection.
    final proceed = await _confirmDownload(descriptor);
    if (proceed != true) return;
    if (!mounted) return;

    _log.i('download start', {'id': modelId, 'sizeBytes': descriptor.sizeBytes});
    Haptics.tap();
    // If another download is already running, cancel both the stream
    // subscription AND the in-flight HTTP work — otherwise the old
    // request keeps writing bytes and progress events race with the
    // new stream's UI updates.
    final previousKind = _activeDownloadKind;
    if (previousKind != null && previousKind != kind) {
      final prevId = previousKind.modelId;
      if (prevId != null) {
        _log.i('superseding active download', {
          'oldId': prevId,
          'newId': modelId,
        });
        widget.downloader.cancel(prevId);
      }
    }
    await _activeSub?.cancel();
    final destPath = await widget.registry.cache.destinationPathFor(descriptor);
    if (!mounted) return;
    final stream = widget.downloader.download(
      descriptor: descriptor,
      destinationPath: destPath,
    );
    _activeDownloadKind = kind;
    _activeSub = stream.listen(
      (event) async {
        if (!mounted) return;
        setState(() => _progress[kind] = event);
        if (event is DownloadComplete) {
          _log.i('download complete', {
            'id': event.modelId,
            'path': event.localPath,
            'bytes': event.sizeBytes,
          });
          // Persist the entry so the registry sees it next resolve().
          await widget.registry.cache.put(
            ModelCacheEntry(
              modelId: event.modelId,
              version: descriptor.version,
              path: event.localPath,
              sizeBytes: event.sizeBytes,
              sha256: descriptor.sha256,
              downloadedAt: DateTime.now(),
            ),
          );
          if (!mounted) return;
          _activeDownloadKind = null;
          Haptics.impact();
          UserFeedback.success(context,
              'Downloaded ${descriptor.id} (${descriptor.sizeDisplay})');
          await _refreshAll();
        } else if (event is DownloadFailed) {
          _log.w('download failed', {
            'id': event.modelId,
            'stage': event.stage.name,
            'message': event.message,
          });
          if (!mounted) return;
          _activeDownloadKind = null;
          Haptics.warning();
          UserFeedback.error(context,
              'Download failed: ${event.stage.userMessage}');
        }
      },
      onError: (Object e, StackTrace st) {
        _log.e('download stream error', error: e, stackTrace: st);
      },
    );
  }

  void _cancelDownload(BgRemovalStrategyKind kind) {
    final modelId = kind.modelId;
    if (modelId == null) return;
    _log.i('download cancel', {'id': modelId});
    widget.downloader.cancel(modelId);
    _activeDownloadKind = null;
    setState(() => _progress.remove(kind));
  }

  Future<bool?> _confirmDownload(ModelDescriptor d) async {
    return showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Download ${d.id}?'),
        content: Text(
          'This will download ${d.sizeDisplay} over your current '
          'connection. Avoid cellular if you pay for data.\n\n${d.purpose}',
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

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(Spacing.lg),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Text(
                    'Remove background',
                    style: theme.textTheme.titleLarge,
                  ),
                  const Spacer(),
                  IconButton(
                    tooltip: 'Close',
                    icon: const Icon(Icons.close),
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                ],
              ),
              const SizedBox(height: Spacing.xs),
              Text(
                'Pick how the subject should be extracted. Downloaded '
                'models give better edges but need a one-time fetch.',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: Spacing.lg),
              for (final kind in BgRemovalStrategyKind.values)
                Padding(
                  padding: const EdgeInsets.only(bottom: Spacing.sm),
                  child: _StrategyCard(
                    kind: kind,
                    descriptor: kind.modelId != null
                        ? widget.registry.descriptor(kind.modelId!)
                        : null,
                    availability: _availability[kind],
                    loadingAvailability: _loadingAvailability.contains(kind),
                    progress: _progress[kind],
                    onUse: () {
                      _log.i('use', {'kind': kind.name});
                      Haptics.tap();
                      Navigator.of(context).pop(kind);
                    },
                    onDownload: () => _startDownload(kind),
                    onCancelDownload: () => _cancelDownload(kind),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _StrategyCard extends StatelessWidget {
  const _StrategyCard({
    required this.kind,
    required this.descriptor,
    required this.availability,
    required this.loadingAvailability,
    required this.progress,
    required this.onUse,
    required this.onDownload,
    required this.onCancelDownload,
  });

  final BgRemovalStrategyKind kind;
  final ModelDescriptor? descriptor;
  final BgRemovalAvailability? availability;
  final bool loadingAvailability;
  final DownloadProgress? progress;
  final VoidCallback onUse;
  final VoidCallback onDownload;
  final VoidCallback onCancelDownload;

  bool get _isRunningDownload => progress is DownloadRunning;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final statusChip = _buildStatusChip(theme);
    final sizeChip = descriptor != null ? _buildSizeChip(theme) : null;
    final action = _buildAction(theme);

    return Material(
      color: theme.colorScheme.surfaceContainerHighest,
      borderRadius: BorderRadius.circular(12),
      child: Padding(
        padding: const EdgeInsets.all(Spacing.md),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(_iconFor(kind), color: theme.colorScheme.primary),
                const SizedBox(width: Spacing.sm),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        kind.label,
                        style: theme.textTheme.titleMedium,
                      ),
                      const SizedBox(height: 2),
                      Text(
                        kind.description,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: Spacing.sm),
            Wrap(
              spacing: Spacing.xs,
              runSpacing: Spacing.xs,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                statusChip,
                ?sizeChip,
              ],
            ),
            if (_isRunningDownload) ...[
              const SizedBox(height: Spacing.sm),
              _buildProgressBar(theme),
            ],
            const SizedBox(height: Spacing.sm),
            Align(
              alignment: Alignment.centerRight,
              child: action,
            ),
          ],
        ),
      ),
    );
  }

  IconData _iconFor(BgRemovalStrategyKind k) {
    switch (k) {
      case BgRemovalStrategyKind.mediaPipe:
        return Icons.speed_outlined;
      case BgRemovalStrategyKind.modnet:
        return Icons.portrait_outlined;
      case BgRemovalStrategyKind.rmbg:
        return Icons.auto_awesome_outlined;
      case BgRemovalStrategyKind.generalOffline:
        return Icons.cloud_off_outlined;
    }
  }

  Widget _buildStatusChip(ThemeData theme) {
    String label;
    Color? bg;
    IconData? icon;
    if (loadingAvailability) {
      label = 'Checking…';
      bg = theme.colorScheme.secondaryContainer;
      icon = Icons.hourglass_empty;
    } else if (_isRunningDownload) {
      final running = progress as DownloadRunning;
      final pct = running.fraction == null
          ? ''
          : ' ${(running.fraction! * 100).round()}%';
      label = 'Downloading$pct';
      bg = theme.colorScheme.primaryContainer;
      icon = Icons.downloading;
    } else if (progress is DownloadFailed) {
      label = 'Download failed';
      bg = theme.colorScheme.errorContainer;
      icon = Icons.error_outline;
    } else {
      switch (availability) {
        case null:
          label = 'Unknown';
          bg = theme.colorScheme.surfaceContainerHigh;
          icon = Icons.help_outline;
          break;
        case BgRemovalAvailability.ready:
          label = 'Ready';
          bg = theme.colorScheme.tertiaryContainer;
          icon = Icons.check_circle_outline;
          break;
        case BgRemovalAvailability.downloadRequired:
          label = 'Download required';
          bg = theme.colorScheme.secondaryContainer;
          icon = Icons.cloud_download_outlined;
          break;
        case BgRemovalAvailability.unknownModel:
          label = 'Unavailable';
          bg = theme.colorScheme.errorContainer;
          icon = Icons.warning_amber_outlined;
          break;
      }
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14),
          const SizedBox(width: 4),
          Text(label, style: theme.textTheme.labelSmall),
        ],
      ),
    );
  }

  Widget _buildSizeChip(ThemeData theme) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        descriptor!.sizeDisplay,
        style: theme.textTheme.labelSmall,
      ),
    );
  }

  Widget _buildProgressBar(ThemeData theme) {
    final running = progress as DownloadRunning;
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

  Widget _buildAction(ThemeData theme) {
    if (_isRunningDownload) {
      return TextButton.icon(
        icon: const Icon(Icons.close),
        label: const Text('Cancel'),
        onPressed: onCancelDownload,
      );
    }
    if (availability == BgRemovalAvailability.ready) {
      return FilledButton.icon(
        icon: const Icon(Icons.play_arrow),
        label: const Text('Use'),
        onPressed: onUse,
      );
    }
    if (availability == BgRemovalAvailability.downloadRequired) {
      return FilledButton.tonalIcon(
        icon: const Icon(Icons.download),
        label: const Text('Download'),
        onPressed: onDownload,
      );
    }
    if (availability == BgRemovalAvailability.unknownModel) {
      return const SizedBox.shrink();
    }
    return const SizedBox(
      width: 16,
      height: 16,
      child: CircularProgressIndicator(strokeWidth: 2),
    );
  }
}
