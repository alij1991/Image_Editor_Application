import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:permission_handler/permission_handler.dart';

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

class _ScannerCapturePageState extends ConsumerState<ScannerCapturePage>
    with WidgetsBindingObserver {
  DetectorStrategy? _userPick;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState lifecycle) {
    // When the user returns from system Settings (e.g. after toggling
    // Camera ON via the "Open Settings" CTA on the permission error)
    // wipe the stale error so the next Scan tap doesn't echo the old
    // banner. permission_handler can also cache `permanentlyDenied`
    // until the next live `request()` — clearing on resume gives the
    // capture flow a clean retry.
    if (lifecycle == AppLifecycleState.resumed) {
      final notifier = ref.read(scannerNotifierProvider.notifier);
      notifier.clearTransientError();
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(scannerNotifierProvider);
    final theme = Theme.of(context);
    final recommended =
        state.capabilities?.recommended ?? DetectorStrategy.manual;
    final chosen = _userPick ?? recommended;

    return Scaffold(
      appBar: AppBar(
        // Explicit Home button — this route is reached via `context.go`
        // (which replaces the stack), so there is no implicit back
        // arrow. Without this the user lands on the scanner landing
        // page with no way back to the main menu short of killing the
        // app — exactly the "no back button to go to main page" report
        // we got from the field.
        leading: IconButton(
          tooltip: 'Home',
          icon: const Icon(Icons.home_outlined),
          onPressed: () => context.go('/'),
        ),
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
                _ErrorBanner(
                  message: state.error!,
                  showOpenSettings: state.permissionBlockedRequiresSettings,
                ),
              ],
              const SizedBox(height: Spacing.md),
              const _CaptureTipsCard(),
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
    final caps = ref.read(scannerNotifierProvider).capabilities;
    final recommended = caps?.recommended ?? DetectorStrategy.manual;
    // Surface the probe's reason so the disabled tile explains itself
    // (e.g. "Google Play Services is missing on this device.").
    final nativeReason = (caps != null && !caps.supportsNative)
        ? (caps.nativeUnavailableReason ??
            'Native scanner is not supported on this device.')
        : null;
    final picked = await showStrategyPicker(
      context,
      recommended: recommended,
      current: _userPick ?? recommended,
      nativeDisabledReason: nativeReason,
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
  const _ErrorBanner({
    required this.message,
    this.showOpenSettings = false,
  });
  final String message;

  /// When the underlying failure was a permanently-denied permission,
  /// add an "Open Settings" button so the user has a one-tap path to
  /// the OS permission screen — the in-app dialog can't be re-shown.
  final bool showOpenSettings;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.all(Spacing.md),
      decoration: BoxDecoration(
        color: theme.colorScheme.errorContainer,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
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
          if (showOpenSettings) ...[
            const SizedBox(height: Spacing.sm),
            Align(
              alignment: Alignment.centerRight,
              child: TextButton.icon(
                icon: const Icon(Icons.settings_outlined, size: 18),
                label: const Text('Open Settings'),
                onPressed: openAppSettings,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// Compact, persistently-collapsible tips card. Surfaces three rules
/// of thumb that materially improve auto-detection success without
/// reading like a manual: even lighting, document fully in frame,
/// and a contrasting background.
class _CaptureTipsCard extends StatelessWidget {
  const _CaptureTipsCard();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Material(
      color: theme.colorScheme.surfaceContainerHighest,
      borderRadius: BorderRadius.circular(12),
      child: ExpansionTile(
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.all(Radius.circular(12)),
        ),
        collapsedShape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.all(Radius.circular(12)),
        ),
        leading: Icon(
          Icons.tips_and_updates_outlined,
          color: theme.colorScheme.primary,
        ),
        title: Text(
          'Tips for cleaner scans',
          style: theme.textTheme.titleSmall,
        ),
        childrenPadding: const EdgeInsets.fromLTRB(
          Spacing.lg,
          0,
          Spacing.lg,
          Spacing.md,
        ),
        children: const [
          _TipRow(
            icon: Icons.wb_sunny_outlined,
            text: 'Even lighting — avoid hard shadows from windows or '
                'overhead lamps.',
          ),
          _TipRow(
            icon: Icons.crop_din,
            text: 'Keep all four corners of the page in frame, with a '
                'small margin around the edges.',
          ),
          _TipRow(
            icon: Icons.invert_colors,
            text: 'Place the page on a contrasting surface (light page on '
                'dark desk, or vice versa) so the auto-detector can find '
                'the boundary.',
          ),
        ],
      ),
    );
  }
}

class _TipRow extends StatelessWidget {
  const _TipRow({required this.icon, required this.text});
  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: Spacing.sm),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 18, color: theme.colorScheme.onSurfaceVariant),
          const SizedBox(width: Spacing.sm),
          Expanded(
            child: Text(
              text,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
