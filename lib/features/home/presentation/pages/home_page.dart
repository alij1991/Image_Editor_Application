import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:image_picker/image_picker.dart';

import '../../../../core/feedback/user_feedback.dart';
import '../../../../core/logging/app_logger.dart';
import '../../../../core/platform/haptics.dart';
import '../../../../core/theme/spacing.dart';
import '../../../../core/theme/theme_mode_controller.dart';

final _log = AppLogger('HomePage');

/// Landing page with gallery + camera CTAs and a hint card explaining
/// what the editor does. Phase 12 will add a gallery / recent edits
/// section here.
class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  /// True while the system image-picker dialog is open. Guards against
  /// a second tap queueing another pickImage() call (the picker
  /// plugin's behaviour on rapid double-tap is platform-specific —
  /// safer to gate at the UI layer). Also drives the CTA tiles' busy
  /// styling so the user sees the tap registered.
  bool _picking = false;

  Future<void> _pickFrom(BuildContext context, ImageSource source) async {
    if (_picking) {
      _log.d('pick rejected — already picking', {'source': source.name});
      return;
    }
    _log.i('pick tapped', {'source': source.name});
    Haptics.tap();
    setState(() => _picking = true);
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
    } finally {
      if (mounted) setState(() => _picking = false);
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
          const _ThemeToggleAction(),
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
                          busy: _picking,
                          onTap: _picking
                              ? null
                              : () {
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
                          onTap: _picking
                              ? null
                              : () {
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
                          onTap: _picking ? null : () async {
                            _log.i('collage tapped');
                            Haptics.tap();
                            // The /collage route is wired by the collage
                            // feature module. If the module isn't loaded
                            // yet (route not registered) GoRouter throws
                            // — catch it and show a friendly message so
                            // the home page stays resilient.
                            // Two failure modes: GoError = route not
                            // registered (collage module unloaded → show
                            // a friendly hint); anything else = real
                            // bug, surface so it gets reported instead
                            // of being swallowed as "coming soon".
                            try {
                              context.go('/collage');
                            } on GoError catch (e) {
                              _log.w('collage route missing',
                                  {'msg': e.message});
                              UserFeedback.info(
                                context,
                                'Collage — coming soon',
                              );
                            } catch (e, st) {
                              _log.e('collage navigation failed',
                                  error: e, stackTrace: st);
                              UserFeedback.error(
                                context,
                                'Could not open collage: $e',
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
                    onPressed: _picking
                        ? null
                        : () => _pickFrom(context, ImageSource.camera),
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
    this.busy = false,
  });

  final IconData icon;
  final String label;

  /// Null disables the tile (the InkWell goes unresponsive and the
  /// tile fades). Used by the home page to gate against double-taps
  /// while the system image-picker is open.
  final VoidCallback? onTap;

  /// When true, replace the icon with a small spinner so the user
  /// sees that the tile they just tapped is doing work. Disables
  /// taps independently of [onTap] for clarity.
  final bool busy;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final disabled = onTap == null;
    return Opacity(
      opacity: disabled && !busy ? 0.5 : 1.0,
      child: Material(
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
                if (busy)
                  SizedBox(
                    width: 32,
                    height: 32,
                    child: CircularProgressIndicator(
                      strokeWidth: 2.5,
                      valueColor: AlwaysStoppedAnimation<Color>(
                        theme.colorScheme.onPrimaryContainer,
                      ),
                    ),
                  )
                else
                  Icon(icon,
                      size: 32, color: theme.colorScheme.onPrimaryContainer),
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

/// App-bar action that cycles theme mode (dark → light → system → dark)
/// and persists the choice. Icon mirrors the active mode so the user
/// can see at a glance what they're switching from.
class _ThemeToggleAction extends ConsumerWidget {
  const _ThemeToggleAction();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final mode = ref.watch(themeModeControllerProvider);
    final controller = ref.read(themeModeControllerProvider.notifier);
    final (icon, label) = switch (mode) {
      ThemeMode.dark => (Icons.dark_mode, 'Dark'),
      ThemeMode.light => (Icons.light_mode, 'Light'),
      ThemeMode.system => (Icons.brightness_auto, 'System'),
    };
    return IconButton(
      tooltip: 'Theme: $label (tap to change)',
      icon: Icon(icon),
      onPressed: () {
        Haptics.tap();
        controller.cycle();
      },
    );
  }
}
