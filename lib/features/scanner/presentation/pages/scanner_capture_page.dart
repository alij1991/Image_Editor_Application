import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../../core/logging/app_logger.dart';
import '../../../../core/platform/haptics.dart';
import '../../../../core/theme/spacing.dart';
import '../../application/providers.dart';
import '../../application/scanner_notifier.dart';
import '../../domain/models/scan_models.dart';
import '../../infrastructure/manual_document_detector.dart';
import '../widgets/strategy_picker.dart';

final _log = AppLogger('ScanCapture');

/// Landing page for the scanner flow: explains what the feature does,
/// shows the recommended detection mode, and launches capture.
class ScannerCapturePage extends ConsumerStatefulWidget {
  const ScannerCapturePage({super.key});

  @override
  ConsumerState<ScannerCapturePage> createState() => _ScannerCapturePageState();
}

class _ScannerCapturePageState extends ConsumerState<ScannerCapturePage> {
  DetectorStrategy? _userPick;

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(scannerNotifierProvider);
    final theme = Theme.of(context);
    final recommended =
        state.capabilities?.recommended ?? DetectorStrategy.manual;
    final chosen = _userPick ?? recommended;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Scan document'),
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(Spacing.xl),
          child: Column(
            children: [
              const Spacer(),
              Icon(
                Icons.document_scanner_outlined,
                size: 96,
                color: theme.colorScheme.primary,
              ),
              const SizedBox(height: Spacing.md),
              Text(
                'Scan to PDF',
                style: theme.textTheme.headlineSmall?.copyWith(
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: Spacing.xs),
              Text(
                'Capture documents, receipts, and whiteboards — '
                'then export them as searchable PDF or text.',
                textAlign: TextAlign.center,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: Spacing.xl),
              _ModeCard(
                strategy: chosen,
                isRecommended: chosen == recommended,
                onTap: state.isBusy ? null : _pickStrategy,
              ),
              if (state.error != null) ...[
                const SizedBox(height: Spacing.md),
                _ErrorBanner(message: state.error!),
              ],
              const Spacer(),
              FilledButton.icon(
                icon: state.isBusy
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.camera_alt_outlined),
                label: Text(state.isBusy
                    ? (state.busyLabel ?? 'Working…')
                    : 'Start scanning'),
                onPressed: state.isBusy ? null : () => _start(chosen),
              ),
              const SizedBox(height: Spacing.sm),
              TextButton(
                onPressed: state.isBusy ? null : _pickStrategy,
                child: const Text('Change detection mode'),
              ),
              const SizedBox(height: Spacing.sm),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _pickStrategy() async {
    final recommended =
        ref.read(scannerNotifierProvider).capabilities?.recommended ??
            DetectorStrategy.manual;
    final picked = await showStrategyPicker(
      context,
      recommended: recommended,
      current: _userPick ?? recommended,
    );
    if (picked == null) return;
    setState(() => _userPick = picked);
    _log.i('strategy chosen', {'strategy': picked.name});
  }

  Future<void> _start(DetectorStrategy strategy) async {
    Haptics.tap();

    // Manual + Auto need to know whether to open the camera or gallery.
    var pickSource = ManualPickSource.askUser;
    if (strategy != DetectorStrategy.native) {
      final chosen = await _askSource();
      if (chosen == null) return; // user cancelled
      pickSource = chosen;
    }

    final notifier = ref.read(scannerNotifierProvider.notifier);
    final outcome = await notifier.startCapture(strategy, pickSource: pickSource);
    if (!mounted) return;
    switch (outcome) {
      case CaptureOutcome.gotoReview:
        context.go('/scanner/review');
        break;
      case CaptureOutcome.gotoCrop:
        context.go('/scanner/crop');
        break;
      case CaptureOutcome.cancelled:
        break;
      case CaptureOutcome.failed:
        // Error is already shown via the inline banner on this page —
        // avoid stacking a redundant snackbar on top of it.
        break;
    }
  }

  Future<ManualPickSource?> _askSource() async {
    return showModalBottomSheet<ManualPickSource>(
      context: context,
      showDragHandle: true,
      builder: (_) => SafeArea(
        child: Wrap(
          children: [
            ListTile(
              leading: const Icon(Icons.photo_camera_outlined),
              title: const Text('Take a photo'),
              onTap: () =>
                  Navigator.of(context).pop(ManualPickSource.camera),
            ),
            ListTile(
              leading: const Icon(Icons.photo_library_outlined),
              title: const Text('Pick from gallery'),
              subtitle: const Text('Select one or more pages'),
              onTap: () =>
                  Navigator.of(context).pop(ManualPickSource.gallery),
            ),
          ],
        ),
      ),
    );
  }
}

class _ModeCard extends StatelessWidget {
  const _ModeCard({
    required this.strategy,
    required this.isRecommended,
    required this.onTap,
  });

  final DetectorStrategy strategy;
  final bool isRecommended;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      clipBehavior: Clip.hardEdge,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(Spacing.md),
          child: Row(
            children: [
              Icon(
                _iconFor(strategy),
                size: 28,
                color: theme.colorScheme.primary,
              ),
              const SizedBox(width: Spacing.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(
                      children: [
                        Text(strategy.label, style: theme.textTheme.titleMedium),
                        const SizedBox(width: Spacing.sm),
                        if (isRecommended)
                          const _Badge(text: 'Recommended'),
                      ],
                    ),
                    const SizedBox(height: Spacing.xxs),
                    Text(
                      strategy.description,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              const Icon(Icons.chevron_right),
            ],
          ),
        ),
      ),
    );
  }

  IconData _iconFor(DetectorStrategy s) => switch (s) {
        DetectorStrategy.native => Icons.document_scanner_outlined,
        DetectorStrategy.manual => Icons.crop_free,
        DetectorStrategy.auto => Icons.auto_awesome,
      };
}

class _Badge extends StatelessWidget {
  const _Badge({required this.text});
  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: theme.colorScheme.primary,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        text,
        style: theme.textTheme.labelSmall?.copyWith(
          color: theme.colorScheme.onPrimary,
          fontWeight: FontWeight.bold,
        ),
      ),
    );
  }
}

class _ErrorBanner extends StatelessWidget {
  const _ErrorBanner({required this.message});
  final String message;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.all(Spacing.md),
      decoration: BoxDecoration(
        color: theme.colorScheme.errorContainer,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        children: [
          Icon(Icons.error_outline,
              color: theme.colorScheme.onErrorContainer, size: 20),
          const SizedBox(width: Spacing.sm),
          Expanded(
            child: Text(
              message,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onErrorContainer,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
