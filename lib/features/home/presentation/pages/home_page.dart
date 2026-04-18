import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:image_picker/image_picker.dart';

import '../../../../core/feedback/user_feedback.dart';
import '../../../../core/logging/app_logger.dart';
import '../../../../core/platform/haptics.dart';
import '../../../../core/theme/spacing.dart';

final _log = AppLogger('HomePage');

/// Landing page with gallery + camera CTAs and a hint card explaining
/// what the editor does. Phase 12 will add a gallery / recent edits
/// section here.
class HomePage extends StatelessWidget {
  const HomePage({super.key});

  Future<void> _pickFrom(BuildContext context, ImageSource source) async {
    _log.i('pick tapped', {'source': source.name});
    Haptics.tap();
    final picker = ImagePicker();
    try {
      final picked = await picker.pickImage(source: source);
      if (picked == null) {
        _log.d('pick cancelled', {'source': source.name});
        return;
      }
      _log.i('picked', {'path': picked.path, 'name': picked.name});
      if (!context.mounted) return;
      context.go('/editor', extra: picked.path);
    } catch (e, st) {
      _log.e('pick failed', error: e, stackTrace: st);
      if (!context.mounted) return;
      UserFeedback.error(context, 'Could not load image: $e');
    }
  }

  void _showAbout(BuildContext context) {
    _log.i('about tapped');
    showAboutDialog(
      context: context,
      applicationName: 'Image Editor',
      applicationVersion: '0.1.0',
      applicationLegalese:
          '© 2026 — A non-destructive photo editor built with Flutter.',
      children: [
        const SizedBox(height: Spacing.md),
        const Text(
          'All edits are stored as parameters — your original photo is never '
          'modified. Pick a photo from your gallery or take a new one to start.',
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Image Editor'),
        actions: [
          IconButton(
            tooltip: 'Scan history',
            icon: const Icon(Icons.history),
            onPressed: () {
              _log.i('history tapped');
              context.go('/scanner/history');
            },
          ),
          IconButton(
            tooltip: 'About',
            icon: const Icon(Icons.info_outline),
            onPressed: () => _showAbout(context),
          ),
        ],
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          // Wrap the column so the layout never overflows on short
          // viewports (some Android phones, landscape orientation, or
          // when the system is showing extra UI like a Now Playing
          // notch). The Spacer below collapses gracefully when there's
          // less than the full viewport available.
          padding: const EdgeInsets.all(Spacing.xl),
          child: ConstrainedBox(
            constraints: BoxConstraints(
              minHeight:
                  MediaQuery.of(context).size.height -
                  MediaQuery.of(context).padding.top -
                  MediaQuery.of(context).padding.bottom -
                  kToolbarHeight -
                  Spacing.xl * 2,
            ),
            child: IntrinsicHeight(
              child: Column(
                children: [
                  const Spacer(),
                  Icon(
                    Icons.auto_fix_high,
                    size: 96,
                    color: theme.colorScheme.primary,
                  ),
                  const SizedBox(height: Spacing.md),
                  Text(
                    'Image Editor',
                    style: theme.textTheme.headlineSmall?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: Spacing.xs),
                  Text(
                    'Professional, non-destructive photo editing',
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: Spacing.xl),
                  _HintCard(),
                  const Spacer(),
                  // Primary CTA row: three big tiles mirroring Google Photos /
                  // Apple Photos' create-surface UX.
                  Row(
                    children: [
                      Expanded(
                        child: _CtaTile(
                          icon: Icons.auto_fix_high,
                          label: 'Edit photo',
                          onTap: () {
                            _log.i('edit tapped');
                            Haptics.tap();
                            _pickFrom(context, ImageSource.gallery);
                          },
                        ),
                      ),
                      const SizedBox(width: Spacing.sm),
                      Expanded(
                        child: _CtaTile(
                          icon: Icons.document_scanner_outlined,
                          label: 'Scan document',
                          onTap: () {
                            _log.i('scan tapped');
                            Haptics.tap();
                            context.go('/scanner');
                          },
                        ),
                      ),
                      const SizedBox(width: Spacing.sm),
                      Expanded(
                        child: _CtaTile(
                          icon: Icons.grid_view_rounded,
                          label: 'Make collage',
                          onTap: () async {
                            _log.i('collage tapped');
                            Haptics.tap();
                            // The /collage route is wired by the collage
                            // feature module. If the module isn't loaded
                            // yet (route not registered) GoRouter throws
                            // — catch it and show a friendly message so
                            // the home page stays resilient.
                            try {
                              context.go('/collage');
                            } catch (_) {
                              UserFeedback.info(
                                context,
                                'Collage — coming soon',
                              );
                            }
                          },
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: Spacing.md),
                  // Secondary row: camera shortcut (direct-capture).
                  OutlinedButton.icon(
                    icon: const Icon(Icons.photo_camera_outlined),
                    label: const Text('Take a photo'),
                    onPressed: () => _pickFrom(context, ImageSource.camera),
                  ),
                  const SizedBox(height: Spacing.xl),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Large tappable tile used in the 3-CTA row on the home screen.
/// Mirrors the create-surface tiles in Google Photos / Apple Photos:
/// big icon, single-word label, generous touch target.
class _CtaTile extends StatelessWidget {
  const _CtaTile({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Material(
      color: theme.colorScheme.primaryContainer,
      borderRadius: BorderRadius.circular(14),
      clipBehavior: Clip.hardEdge,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(
            vertical: Spacing.lg,
            horizontal: Spacing.sm,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 32, color: theme.colorScheme.onPrimaryContainer),
              const SizedBox(height: Spacing.sm),
              Text(
                label,
                textAlign: TextAlign.center,
                style: theme.textTheme.labelLarge?.copyWith(
                  color: theme.colorScheme.onPrimaryContainer,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _HintCard extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(Spacing.lg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                Icon(
                  Icons.tips_and_updates_outlined,
                  size: 20,
                  color: theme.colorScheme.primary,
                ),
                const SizedBox(width: Spacing.sm),
                Text('Quick tips', style: theme.textTheme.titleSmall),
              ],
            ),
            const SizedBox(height: Spacing.sm),
            const _HintLine(
              icon: Icons.palette_outlined,
              text:
                  '6 tool categories: Light, Color, Effects, Detail, Optics, Geometry',
            ),
            const _HintLine(
              icon: Icons.swipe_outlined,
              text:
                  'Swipe horizontally on the photo to adjust, vertically to switch parameters',
            ),
            const _HintLine(
              icon: Icons.compare_outlined,
              text: 'Hold the compare button to see the original at any time',
            ),
            const _HintLine(
              icon: Icons.undo_outlined,
              text: 'Undo / Redo every step — your original is never changed',
            ),
          ],
        ),
      ),
    );
  }
}

class _HintLine extends StatelessWidget {
  const _HintLine({required this.icon, required this.text});
  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: Spacing.xs),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 16, color: theme.colorScheme.onSurfaceVariant),
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
