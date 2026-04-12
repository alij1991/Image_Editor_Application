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
            tooltip: 'About',
            icon: const Icon(Icons.info_outline),
            onPressed: () => _showAbout(context),
          ),
        ],
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(Spacing.xl),
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
              FilledButton.icon(
                icon: const Icon(Icons.photo_library_outlined),
                label: const Text('Choose from gallery'),
                onPressed: () => _pickFrom(context, ImageSource.gallery),
              ),
              const SizedBox(height: Spacing.sm),
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
                Text(
                  'Quick tips',
                  style: theme.textTheme.titleSmall,
                ),
              ],
            ),
            const SizedBox(height: Spacing.sm),
            const _HintLine(
              icon: Icons.palette_outlined,
              text: '6 tool categories: Light, Color, Effects, Detail, Optics, Geometry',
            ),
            const _HintLine(
              icon: Icons.swipe_outlined,
              text: 'Swipe horizontally on the photo to adjust, vertically to switch parameters',
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
          Icon(
            icon,
            size: 16,
            color: theme.colorScheme.onSurfaceVariant,
          ),
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
