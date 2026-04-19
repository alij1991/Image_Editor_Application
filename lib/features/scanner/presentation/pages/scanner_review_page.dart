import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../../core/feedback/user_feedback.dart';
import '../../../../core/logging/app_logger.dart';
import '../../../../core/platform/haptics.dart';
import '../../../../core/theme/spacing.dart';
import '../../application/providers.dart';
import '../../application/scanner_notifier.dart';
import '../../domain/document_classifier.dart';
import '../../domain/models/scan_models.dart';
import '../widgets/filter_chip_row.dart';
import '../widgets/page_thumbnail_strip.dart';

final _log = AppLogger('ScanReview');

/// Review page: shows the currently-selected scanned page in a large
/// preview, with filter chips, rotate, delete, and a thumbnail strip
/// for multi-page navigation.
class ScannerReviewPage extends ConsumerStatefulWidget {
  const ScannerReviewPage({super.key});

  @override
  ConsumerState<ScannerReviewPage> createState() => _ScannerReviewPageState();
}

class _ScannerReviewPageState extends ConsumerState<ScannerReviewPage> {
  String? _selectedId;

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(scannerNotifierProvider);
    final session = state.session;
    if (session == null || session.pages.isEmpty) {
      return Scaffold(
        appBar: AppBar(title: const Text('Review')),
        body: const Center(child: Text('No pages to review yet.')),
      );
    }
    final selected = _selectedPage(session);

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        final keep = await _confirmDiscard();
        if (keep != true) return;
        if (!context.mounted) return;
        ref.read(scannerNotifierProvider.notifier).clear();
        context.go('/');
      },
      child: _buildScaffold(context, state, session, selected),
    );
  }

  Future<bool?> _confirmDiscard() {
    return showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Discard scan?'),
        content: const Text(
          'Leaving now will discard the pages you just captured. '
          'Tap Export first to save them.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Keep scanning'),
          ),
          FilledButton.tonal(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Discard'),
          ),
        ],
      ),
    );
  }

  Scaffold _buildScaffold(
    BuildContext context,
    ScannerState state,
    ScanSession session,
    ScanPage selected,
  ) {
    return Scaffold(
      appBar: AppBar(
        title: Text('Review (${session.pages.length} page'
            '${session.pages.length == 1 ? '' : 's'})'),
        actions: [
          IconButton(
            tooltip: 'Rotate',
            icon: const Icon(Icons.rotate_90_degrees_ccw_outlined),
            onPressed: () {
              Haptics.tap();
              ref
                  .read(scannerNotifierProvider.notifier)
                  .rotatePage(selected.id, 90);
            },
          ),
          IconButton(
            tooltip: 'Auto straighten',
            icon: const Icon(Icons.straighten),
            onPressed: () async {
              Haptics.tap();
              await ref
                  .read(scannerNotifierProvider.notifier)
                  .autoDeskewPage(selected.id);
              if (!context.mounted) return;
              UserFeedback.info(context, 'Auto-straighten applied');
            },
          ),
          PopupMenuButton<String>(
            onSelected: (v) async {
              switch (v) {
                case 'autoRotate':
                  Haptics.tap();
                  await ref
                      .read(scannerNotifierProvider.notifier)
                      .autoRotatePage(selected.id);
                  if (!context.mounted) return;
                  UserFeedback.info(context, 'Auto-rotate applied');
                  break;
                case 'smartFilter':
                  Haptics.tap();
                  final type = await ref
                      .read(scannerNotifierProvider.notifier)
                      .classifyPage(selected.id);
                  if (!context.mounted) return;
                  if (type == null || type == DocumentType.unknown) {
                    UserFeedback.info(
                      context,
                      "Couldn't suggest a filter for this page.",
                    );
                    break;
                  }
                  ref
                      .read(scannerNotifierProvider.notifier)
                      .setFilter(selected.id, type.suggestedFilter);
                  UserFeedback.info(
                    context,
                    'Detected ${type.label} → ${type.suggestedFilter.label}',
                  );
                  break;
                case 'editor':
                  _log.i('open in editor', {'page': selected.id});
                  final path = selected.processedImagePath;
                  if (path == null) {
                    UserFeedback.info(
                        context, 'Still processing — try again in a moment.');
                    return;
                  }
                  context.go('/editor', extra: path);
                  break;
                case 'recrop':
                  _log.i('recrop', {'page': selected.id});
                  context.go('/scanner/crop');
                  break;
              }
            },
            itemBuilder: (_) {
              // "Re-crop" only makes sense when the raw source differs
              // from the current processed output — that's the case for
              // Manual/Auto strategies. Native pages are already
              // perfectly cropped by the platform scanner.
              final canRecrop =
                  session.strategy != DetectorStrategy.native;
              return [
                const PopupMenuItem(
                  value: 'autoRotate',
                  child: ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: Icon(Icons.screen_rotation_outlined),
                    title: Text('Auto-rotate'),
                  ),
                ),
                const PopupMenuItem(
                  value: 'smartFilter',
                  child: ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: Icon(Icons.auto_awesome_outlined),
                    title: Text('Smart filter'),
                  ),
                ),
                if (canRecrop)
                  const PopupMenuItem(
                    value: 'recrop',
                    child: ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: Icon(Icons.crop_free),
                      title: Text('Re-crop corners'),
                    ),
                  ),
                const PopupMenuItem(
                  value: 'editor',
                  child: ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: Icon(Icons.auto_fix_high_outlined),
                    title: Text('Open in editor'),
                  ),
                ),
              ];
            },
          ),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: _PreviewArea(page: selected),
            ),
            const SizedBox(height: Spacing.sm),
            SizedBox(
              height: 40,
              child: FilterChipRow(
                selected: selected.filter,
                onChanged: (f) {
                  Haptics.tap();
                  ref
                      .read(scannerNotifierProvider.notifier)
                      .setFilter(selected.id, f);
                },
              ),
            ),
            const SizedBox(height: Spacing.sm),
            PageThumbnailStrip(
              pages: session.pages,
              selectedId: selected.id,
              onSelect: (id) => setState(() => _selectedId = id),
              onReorder: (oldI, newI) {
                ref
                    .read(scannerNotifierProvider.notifier)
                    .reorderPage(oldI, newI);
              },
              onRemove: (id) {
                final remainingCount = session.pages.length - 1;
                ref.read(scannerNotifierProvider.notifier).removePage(id);
                if (remainingCount == 0) {
                  _log.i('last page removed, back to capture');
                  context.go('/scanner');
                } else if (id == _selectedId) {
                  setState(() => _selectedId = null);
                }
              },
            ),
            const SizedBox(height: Spacing.md),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: Spacing.lg),
              child: Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      icon: const Icon(Icons.close),
                      label: const Text('Discard'),
                      onPressed: () {
                        _log.i('discarded');
                        ref.read(scannerNotifierProvider.notifier).clear();
                        context.go('/');
                      },
                    ),
                  ),
                  const SizedBox(width: Spacing.sm),
                  Expanded(
                    child: FilledButton.icon(
                      icon: const Icon(Icons.ios_share),
                      label: const Text('Export'),
                      onPressed: () => context.go('/scanner/export'),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: Spacing.md),
          ],
        ),
      ),
    );
  }

  ScanPage _selectedPage(ScanSession s) {
    final id = _selectedId;
    if (id != null) {
      final found = s.pages.firstWhere(
        (p) => p.id == id,
        orElse: () => s.pages.first,
      );
      return found;
    }
    return s.pages.first;
  }
}

class _PreviewArea extends StatelessWidget {
  const _PreviewArea({required this.page});
  final ScanPage page;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final path = page.processedImagePath;
    return Container(
      color: theme.colorScheme.surfaceContainerLow,
      child: path == null
          ? const Center(child: CircularProgressIndicator())
          : InteractiveViewer(
              minScale: 0.8,
              maxScale: 6,
              child: Center(
                child: Image.file(
                  File(path),
                  fit: BoxFit.contain,
                  gaplessPlayback: true,
                  errorBuilder: (_, __, ___) => Padding(
                    padding: const EdgeInsets.all(Spacing.xl),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.broken_image_outlined,
                            color: theme.colorScheme.error),
                        const SizedBox(height: Spacing.sm),
                        const Text('Could not load preview.'),
                      ],
                    ),
                  ),
                ),
              ),
            ),
    );
  }
}
