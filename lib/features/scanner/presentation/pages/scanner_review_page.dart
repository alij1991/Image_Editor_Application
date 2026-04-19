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
import '../../infrastructure/manual_document_detector.dart';
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

  /// Tapping the Home icon in the app bar — gated by the same
  /// confirmation dialog as the system back gesture so the user can't
  /// lose pages by accident. Returns to "/" (main menu) on confirm.
  Future<void> _onHome(BuildContext context) async {
    final keep = await _confirmDiscard();
    if (keep != true) return;
    if (!context.mounted) return;
    ref.read(scannerNotifierProvider.notifier).clear();
    context.go('/');
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
    final notifier = ref.read(scannerNotifierProvider.notifier);
    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          tooltip: 'Home',
          icon: const Icon(Icons.home_outlined),
          onPressed: () => _onHome(context),
        ),
        title: Text('Review (${session.pages.length} page'
            '${session.pages.length == 1 ? '' : 's'})'),
        actions: [
          // Undo / redo for any page-level mutation (filter, crop,
          // rotation, removal, reorder, "+ Add page"). Tapping the
          // disabled state does nothing visually but keeps the bar
          // layout stable so other actions don't jump around as the
          // user edits.
          IconButton(
            tooltip: notifier.canUndo ? 'Undo' : 'Nothing to undo',
            icon: const Icon(Icons.undo),
            onPressed: notifier.canUndo
                ? () {
                    Haptics.tap();
                    notifier.undo();
                  }
                : null,
          ),
          IconButton(
            tooltip: notifier.canRedo ? 'Redo' : 'Nothing to redo',
            icon: const Icon(Icons.redo),
            onPressed: notifier.canRedo
                ? () {
                    Haptics.tap();
                    notifier.redo();
                  }
                : null,
          ),
          IconButton(
            tooltip: 'Rotate',
            icon: const Icon(Icons.rotate_90_degrees_ccw_outlined),
            onPressed: () {
              Haptics.tap();
              notifier.rotatePage(selected.id, 90);
            },
          ),
          IconButton(
            tooltip: 'Auto straighten',
            icon: const Icon(Icons.straighten),
            onPressed: () async {
              Haptics.tap();
              await notifier.autoDeskewPage(selected.id);
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
            const SizedBox(height: Spacing.sm),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: Spacing.lg),
              child: OutlinedButton.icon(
                icon: const Icon(Icons.add_a_photo_outlined),
                label: const Text('Add page'),
                onPressed: () => _addPage(context, ref, session),
              ),
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

  /// Re-invoke the same detector strategy that started the session
  /// and append the captured page(s). Native skips the crop page;
  /// Manual / Auto bounce through it for the new pages only.
  Future<void> _addPage(
    BuildContext context,
    WidgetRef ref,
    ScanSession session,
  ) async {
    Haptics.tap();
    var pickSource = ManualPickSource.askUser;
    if (session.strategy != DetectorStrategy.native) {
      final chosen = await _askSourceFromBottomSheet(context);
      if (chosen == null) return;
      pickSource = chosen;
    }
    final outcome = await ref
        .read(scannerNotifierProvider.notifier)
        .addMorePages(pickSource: pickSource);
    if (!context.mounted) return;
    switch (outcome) {
      case CaptureOutcome.gotoCrop:
        context.go('/scanner/crop');
        break;
      case CaptureOutcome.gotoReview:
        // Already here — nothing to navigate to. Show a confirmation.
        UserFeedback.info(context, 'Pages added');
        break;
      case CaptureOutcome.cancelled:
        break;
      case CaptureOutcome.failed:
        UserFeedback.info(context, 'Could not add pages.');
        break;
    }
  }

  Future<ManualPickSource?> _askSourceFromBottomSheet(BuildContext context) =>
      showModalBottomSheet<ManualPickSource>(
        context: context,
        showDragHandle: true,
        builder: (_) => SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                leading: const Icon(Icons.photo_camera_outlined),
                title: const Text('Take photo'),
                onTap: () =>
                    Navigator.of(context).pop(ManualPickSource.camera),
              ),
              ListTile(
                leading: const Icon(Icons.photo_library_outlined),
                title: const Text('Pick from gallery'),
                onTap: () =>
                    Navigator.of(context).pop(ManualPickSource.gallery),
              ),
            ],
          ),
        ),
      );
}

/// Stateful so we can remember the last successfully-rendered
/// `processedImagePath` per page. While a filter / crop / rotation
/// reprocess is in flight the page's `processedImagePath` clears to
/// null — instead of going to a full-screen spinner (which made
/// users on slow devices think the tap had no effect), we show the
/// stale image dimmed with a small overlay spinner. This is a
/// significantly better feedback signal — the user sees their tap
/// registered AND that the new render isn't ready yet.
class _PreviewArea extends StatefulWidget {
  const _PreviewArea({required this.page});
  final ScanPage page;

  @override
  State<_PreviewArea> createState() => _PreviewAreaState();
}

class _PreviewAreaState extends State<_PreviewArea> {
  String? _lastPath;
  String? _lastPageId;

  @override
  void didUpdateWidget(covariant _PreviewArea old) {
    super.didUpdateWidget(old);
    final p = widget.page.processedImagePath;
    // Reset the cache when the user selects a different page so the
    // wrong page's stale image doesn't ghost in.
    if (widget.page.id != _lastPageId) {
      _lastPath = p;
      _lastPageId = widget.page.id;
    } else if (p != null) {
      _lastPath = p;
    }
  }

  @override
  void initState() {
    super.initState();
    _lastPath = widget.page.processedImagePath;
    _lastPageId = widget.page.id;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final currentPath = widget.page.processedImagePath;
    final isProcessing = currentPath == null;
    final pathToShow = currentPath ?? _lastPath;
    return Container(
      color: theme.colorScheme.surfaceContainerLow,
      child: Stack(
        fit: StackFit.expand,
        children: [
          if (pathToShow != null)
            InteractiveViewer(
              minScale: 0.8,
              maxScale: 6,
              child: Center(
                child: Image.file(
                  File(pathToShow),
                  fit: BoxFit.contain,
                  gaplessPlayback: true,
                  errorBuilder: (_, _, _) => Padding(
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
          if (isProcessing)
            Positioned.fill(
              child: IgnorePointer(
                child: Container(
                  color: Colors.black.withValues(alpha: 0.30),
                  alignment: Alignment.center,
                  child: const _ProcessingPill(),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// Compact "applying…" indicator shown over the dimmed preview
/// during a filter / crop / rotation reprocess.
class _ProcessingPill extends StatelessWidget {
  const _ProcessingPill();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Material(
      color: theme.colorScheme.inverseSurface,
      borderRadius: BorderRadius.circular(20),
      elevation: 4,
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: Spacing.lg,
          vertical: Spacing.sm,
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: theme.colorScheme.onInverseSurface,
              ),
            ),
            const SizedBox(width: Spacing.sm),
            Text(
              'Applying…',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onInverseSurface,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
