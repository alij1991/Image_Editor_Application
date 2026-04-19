import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../../core/logging/app_logger.dart';
import '../../../../core/theme/spacing.dart';
import '../../application/providers.dart';
import '../../domain/models/scan_models.dart';
import '../widgets/corner_editor.dart';

final _log = AppLogger('ScanCrop');

/// Per-page corner-editor step that the Manual and Auto detectors feed
/// into. The user steps through each page, drags corners, and taps
/// "Apply". Once every page is confirmed we jump to the Review page.
class ScannerCropPage extends ConsumerStatefulWidget {
  const ScannerCropPage({super.key});

  @override
  ConsumerState<ScannerCropPage> createState() => _ScannerCropPageState();
}

class _ScannerCropPageState extends ConsumerState<ScannerCropPage> {
  int? _index;
  ScanPage? _editing;
  Corners? _workingCorners;

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(scannerNotifierProvider);
    final session = state.session;
    if (session == null || session.pages.isEmpty) {
      return Scaffold(
        appBar: AppBar(title: const Text('Crop')),
        body: const Center(child: Text('No pages to crop.')),
      );
    }
    // First entry: jump to the first un-processed page so a user
    // who came from "+ Add page" on the review screen doesn't have
    // to re-crop pages they've already finished.
    if (_index == null) {
      final firstNew = session.pages.indexWhere((p) => p.processedImagePath == null);
      _index = firstNew >= 0 ? firstNew : 0;
    }
    final safeIndex = _index!.clamp(0, session.pages.length - 1);
    final page = session.pages[safeIndex];
    // When we advance to a new page, reset the working corners from it.
    if (_editing?.id != page.id) {
      _editing = page;
      _workingCorners = page.corners;
    }
    final corners = _workingCorners ?? page.corners;

    return Scaffold(
      appBar: AppBar(
        title: Text('Crop page ${safeIndex + 1} of ${session.pages.length}'),
        actions: [
          IconButton(
            tooltip: 'Reset corners',
            icon: const Icon(Icons.refresh),
            onPressed: () => setState(() => _workingCorners = Corners.inset()),
          ),
          IconButton(
            tooltip: 'Fit to image',
            icon: const Icon(Icons.fullscreen),
            onPressed: () => setState(() => _workingCorners = Corners.full()),
          ),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            if (state.notice != null)
              _CoachingBanner(
                message: state.notice!,
                onDismiss: () => ref
                    .read(scannerNotifierProvider.notifier)
                    .dismissNotice(),
              ),
            Expanded(
              child: Container(
                color: Colors.black,
                child: CornerEditor(
                  imagePath: page.rawImagePath,
                  corners: corners,
                  onChanged: (c) => setState(() => _workingCorners = c),
                ),
              ),
            ),
            const SizedBox(height: Spacing.md),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: Spacing.lg),
              child: Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      icon: const Icon(Icons.arrow_back),
                      label: Text(safeIndex == 0 ? 'Cancel' : 'Back'),
                      onPressed: () => _back(safeIndex),
                    ),
                  ),
                  const SizedBox(width: Spacing.sm),
                  Expanded(
                    child: FilledButton.icon(
                      icon: const Icon(Icons.check),
                      label: Text(
                        safeIndex == session.pages.length - 1
                            ? 'Apply & continue'
                            : 'Next page',
                      ),
                      onPressed: () => _apply(safeIndex, session),
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

  void _apply(int idx, ScanSession session) {
    final final_ = _workingCorners ?? session.pages[idx].corners;
    _log.i('apply corners', {'page': session.pages[idx].id, 'idx': idx});
    ref
        .read(scannerNotifierProvider.notifier)
        .setCorners(session.pages[idx].id, final_);
    if (idx < session.pages.length - 1) {
      setState(() {
        _index = idx + 1;
        _editing = null;
        _workingCorners = null;
      });
    } else {
      context.go('/scanner/review');
    }
  }

  void _back(int idx) {
    if (idx == 0) {
      ref.read(scannerNotifierProvider.notifier).clear();
      context.go('/scanner');
      return;
    }
    setState(() {
      _index = idx - 1;
      _editing = null;
      _workingCorners = null;
    });
  }
}

/// Inline coaching strip used at the top of the crop page when the
/// notifier surfaces a [ScannerState.notice]. Lower-key visual than
/// an error banner — info icon, surface-tinted background, single-tap
/// dismiss.
class _CoachingBanner extends StatelessWidget {
  const _CoachingBanner({required this.message, required this.onDismiss});

  final String message;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Material(
      color: theme.colorScheme.secondaryContainer,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(
          Spacing.lg,
          Spacing.sm,
          Spacing.sm,
          Spacing.sm,
        ),
        child: Row(
          children: [
            Icon(
              Icons.info_outline,
              size: 20,
              color: theme.colorScheme.onSecondaryContainer,
            ),
            const SizedBox(width: Spacing.sm),
            Expanded(
              child: Text(
                message,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSecondaryContainer,
                ),
              ),
            ),
            IconButton(
              icon: const Icon(Icons.close, size: 18),
              tooltip: 'Dismiss',
              color: theme.colorScheme.onSecondaryContainer,
              onPressed: onDismiss,
            ),
          ],
        ),
      ),
    );
  }
}
