import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../../../core/feedback/user_feedback.dart';
import '../../../../core/logging/app_logger.dart';
import '../../../../core/theme/spacing.dart';
import '../../application/providers.dart';
import '../../domain/models/scan_models.dart';

final _log = AppLogger('ScanHistory');

/// Shows every persisted scan session. Tap opens it in the review page
/// for re-export; swipe/long-press deletes.
class ScannerHistoryPage extends ConsumerWidget {
  const ScannerHistoryPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final historyAsync = ref.watch(scanHistoryProvider);
    return Scaffold(
      appBar: AppBar(
        // Home affordance — the history route is reached via
        // `context.go`, so without this leading button the user has
        // no visible way back to the main menu.
        leading: IconButton(
          tooltip: 'Home',
          icon: const Icon(Icons.home_outlined),
          onPressed: () => context.go('/'),
        ),
        title: const Text('Scan history'),
        actions: [
          IconButton(
            tooltip: 'New scan',
            icon: const Icon(Icons.add),
            onPressed: () => context.go('/scanner'),
          ),
        ],
      ),
      body: historyAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, st) {
          _log.w('history load failed', {'err': e.toString()});
          return Center(
            child: Padding(
              padding: const EdgeInsets.all(Spacing.xl),
              child: Text('Could not load history: $e'),
            ),
          );
        },
        data: (sessions) {
          if (sessions.isEmpty) return const _EmptyHistory();
          return ListView.separated(
            padding: const EdgeInsets.all(Spacing.md),
            itemCount: sessions.length,
            separatorBuilder: (_, __) => const SizedBox(height: Spacing.sm),
            itemBuilder: (_, i) => _HistoryTile(
              session: sessions[i],
              onOpen: () => _open(context, ref, sessions[i]),
              onDelete: () => _delete(context, ref, sessions[i]),
            ),
          );
        },
      ),
    );
  }

  void _open(BuildContext context, WidgetRef ref, ScanSession session) {
    _log.i('open', {'id': session.id, 'pages': session.pages.length});
    ref.read(scannerNotifierProvider.notifier).loadSession(session);
    context.go('/scanner/review');
  }

  Future<void> _delete(
      BuildContext context, WidgetRef ref, ScanSession session) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Delete scan?'),
        content: Text(
          session.title?.isNotEmpty == true
              ? 'Delete "${session.title}"? This cannot be undone.'
              : 'Delete this scan? This cannot be undone.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton.tonal(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirm != true) return;
    await ref.read(scanRepositoryProvider).delete(session.id);
    ref.invalidate(scanHistoryProvider);
    if (!context.mounted) return;
    UserFeedback.info(context, 'Scan deleted');
  }
}

class _HistoryTile extends StatelessWidget {
  const _HistoryTile({
    required this.session,
    required this.onOpen,
    required this.onDelete,
  });

  final ScanSession session;
  final VoidCallback onOpen;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final thumbPath = session.pages.isEmpty
        ? null
        : (session.pages.first.processedImagePath ??
            session.pages.first.rawImagePath);
    final title = session.title?.trim().isNotEmpty == true
        ? session.title!
        : 'Scan ${DateFormat.yMMMd().format(session.createdAt)}';
    final subtitle =
        '${session.pages.length} page${session.pages.length == 1 ? '' : 's'}'
        ' · ${DateFormat.yMMMd().add_jm().format(session.createdAt)}';
    return Card(
      clipBehavior: Clip.hardEdge,
      child: InkWell(
        onTap: onOpen,
        child: Padding(
          padding: const EdgeInsets.all(Spacing.sm),
          child: Row(
            children: [
              SizedBox(
                width: 56,
                height: 72,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(6),
                  child: thumbPath != null && File(thumbPath).existsSync()
                      ? Image.file(File(thumbPath), fit: BoxFit.cover)
                      : Container(
                          color: theme.colorScheme.surfaceContainerHighest,
                          child: const Icon(Icons.description_outlined),
                        ),
                ),
              ),
              const SizedBox(width: Spacing.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.titleMedium),
                    const SizedBox(height: 2),
                    Text(subtitle,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        )),
                  ],
                ),
              ),
              IconButton(
                tooltip: 'Delete',
                icon: const Icon(Icons.delete_outline),
                onPressed: onDelete,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _EmptyHistory extends StatelessWidget {
  const _EmptyHistory();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(Spacing.xl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.history,
                size: 64, color: theme.colorScheme.onSurfaceVariant),
            const SizedBox(height: Spacing.md),
            Text('No saved scans yet', style: theme.textTheme.titleMedium),
            const SizedBox(height: Spacing.xs),
            Text(
              'Every time you export a scan, it lands here so you can '
              're-share or re-export it later.',
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
