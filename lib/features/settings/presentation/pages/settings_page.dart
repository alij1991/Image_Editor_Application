import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:logger/logger.dart' show Level;
import 'package:share_plus/share_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../../core/feedback/user_feedback.dart';
import '../../../../core/logging/app_logger.dart';
import '../../../../core/platform/haptics.dart';
import '../../../../core/preferences/pref_controller.dart';
import '../../../../core/theme/spacing.dart';
import '../../../../core/theme/theme_mode_controller.dart';
import '../../../editor/data/export_history.dart';
import '../widgets/model_manager_sheet.dart';

const String _kPerfHudPref = 'perf_hud_enabled_v1';
const String _kLogLevelPref = 'log_level_v1';

/// Persisted toggle for the dev-mode performance HUD overlay. Off by
/// default — the HUD is suppressed in release builds anyway, but
/// debug-build users can disable it from here when they want a clean
/// canvas for screenshots.
final perfHudEnabledProvider =
    StateNotifierProvider<BoolPrefController, bool>(
  (ref) => BoolPrefController(prefKey: _kPerfHudPref, fallback: true),
);

/// Recent successful exports, freshest first. Refreshed by reading
/// [ExportHistory] each time the Settings page rebuilds — the list
/// is small (≤20 entries) so the cost is trivial. `ref.invalidate`
/// from a delete / clear forces a re-fetch.
final exportHistoryProvider = FutureProvider<List<ExportHistoryEntry>>(
  (ref) => ExportHistory().list(),
);

// X.A.3 — `_BoolPrefController` was inlined here pre-X.A.3; now
// replaced by the shared `BoolPrefController` from
// `lib/core/preferences/pref_controller.dart`. `perfHudEnabledProvider`
// above uses the shared class directly.

/// Single Settings screen consolidating every cross-feature toggle.
/// Replaces the scatter of the home app-bar's About/theme buttons and
/// the editor's "Manage AI models" overflow entry — those entry
/// points still work but route here too so the user has one place to
/// look.
class SettingsPage extends ConsumerWidget {
  const SettingsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final themeMode = ref.watch(themeModeControllerProvider);
    final perfHud = ref.watch(perfHudEnabledProvider);
    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          tooltip: 'Back',
          icon: const Icon(Icons.arrow_back),
          onPressed: () => Navigator.of(context).maybePop(),
        ),
        title: const Text('Settings'),
      ),
      body: ListView(
        children: [
          const _SectionHeader('Appearance'),
          ListTile(
            leading: Icon(_themeIcon(themeMode)),
            title: const Text('Theme'),
            subtitle: Text(_themeLabel(themeMode)),
            trailing: SegmentedButton<ThemeMode>(
              segments: const [
                ButtonSegment(
                  value: ThemeMode.light,
                  icon: Icon(Icons.light_mode, size: 18),
                ),
                ButtonSegment(
                  value: ThemeMode.system,
                  icon: Icon(Icons.brightness_auto, size: 18),
                ),
                ButtonSegment(
                  value: ThemeMode.dark,
                  icon: Icon(Icons.dark_mode, size: 18),
                ),
              ],
              selected: {themeMode},
              onSelectionChanged: (s) {
                Haptics.tap();
                ref
                    .read(themeModeControllerProvider.notifier)
                    .setMode(s.first);
              },
            ),
          ),
          const Divider(),

          const _SectionHeader('AI'),
          ListTile(
            leading: const Icon(Icons.inventory_2_outlined),
            title: const Text('Manage AI models'),
            subtitle: const Text(
                'Download, delete, and update on-device ML models.'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () {
              Haptics.tap();
              ModelManagerSheet.show(context);
            },
          ),
          const Divider(),

          const _SectionHeader('Diagnostics'),
          SwitchListTile(
            secondary: const Icon(Icons.speed_outlined),
            title: const Text('Performance HUD'),
            subtitle: const Text(
                'Show frame-time overlay in the editor (debug builds only).'),
            value: perfHud,
            onChanged: (v) {
              Haptics.tap();
              ref.read(perfHudEnabledProvider.notifier).set(v);
            },
          ),
          ListTile(
            leading: const Icon(Icons.bug_report_outlined),
            title: const Text('Log level'),
            subtitle: Text('Currently: ${AppLogger.level.name}'),
            trailing: DropdownButton<Level>(
              value: AppLogger.level,
              items: const [
                DropdownMenuItem(value: Level.debug, child: Text('Debug')),
                DropdownMenuItem(value: Level.info, child: Text('Info')),
                DropdownMenuItem(value: Level.warning, child: Text('Warning')),
                DropdownMenuItem(value: Level.error, child: Text('Error')),
              ],
              onChanged: (v) async {
                if (v == null) return;
                AppLogger.level = v;
                try {
                  final prefs = await SharedPreferences.getInstance();
                  await prefs.setString(_kLogLevelPref, v.name);
                } catch (_) {}
                if (!context.mounted) return;
                UserFeedback.info(context, 'Log level: ${v.name}');
                // Force a rebuild by invalidating perfHudEnabled —
                // cheap, just so the subtitle text refreshes.
                ref.invalidate(perfHudEnabledProvider);
              },
            ),
          ),
          const Divider(),

          const _SectionHeader('Recent exports'),
          _RecentExportsSection(ref: ref),
          const Divider(),

          const _SectionHeader('About'),
          ListTile(
            leading: Icon(
              Icons.auto_fix_high,
              color: theme.colorScheme.primary,
            ),
            title: const Text('Image Editor'),
            subtitle: const Text('Version 0.1.0'),
            trailing: TextButton(
              onPressed: () {
                showLicensePage(
                  context: context,
                  applicationName: 'Image Editor',
                  applicationVersion: '0.1.0',
                );
              },
              child: const Text('Licenses'),
            ),
          ),
          const SizedBox(height: Spacing.xl),
        ],
      ),
    );
  }

  static IconData _themeIcon(ThemeMode m) => switch (m) {
        ThemeMode.dark => Icons.dark_mode,
        ThemeMode.light => Icons.light_mode,
        ThemeMode.system => Icons.brightness_auto,
      };

  static String _themeLabel(ThemeMode m) => switch (m) {
        ThemeMode.dark => 'Dark — chrome stays dark even in bright light',
        ThemeMode.light => 'Light — easier in daylight',
        ThemeMode.system => 'Match the system theme',
      };
}

/// Hydrate the persisted log level on app start. Call from bootstrap
/// or main so the first-frame logger respects the saved preference.
Future<void> hydratePersistedLogLevel() async {
  try {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_kLogLevelPref);
    if (raw == null) return;
    for (final lvl in Level.values) {
      if (lvl.name == raw) {
        AppLogger.level = lvl;
        return;
      }
    }
  } catch (_) {}
}

/// Vertical list of the user's last few exports. Each row shows the
/// format chip, dimensions, file size, relative timestamp, and a
/// share/delete action. Missing files (the OS swept the temp dir)
/// render with a "missing" badge — the entry can still be removed
/// from history but the share action is disabled.
class _RecentExportsSection extends StatelessWidget {
  const _RecentExportsSection({required this.ref});

  final WidgetRef ref;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final async = ref.watch(exportHistoryProvider);
    return async.when(
      loading: () => const Padding(
        padding: EdgeInsets.all(Spacing.md),
        child: Center(
          child: SizedBox(
            width: 20,
            height: 20,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        ),
      ),
      error: (e, _) => Padding(
        padding: const EdgeInsets.all(Spacing.md),
        child: Text(
          'Could not load history: $e',
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ),
      data: (entries) {
        if (entries.isEmpty) {
          return Padding(
            padding: const EdgeInsets.fromLTRB(
              Spacing.lg,
              Spacing.xs,
              Spacing.lg,
              Spacing.md,
            ),
            child: Text(
              'Nothing exported yet. Tap the share icon in the editor '
              'to render and save a copy.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          );
        }
        return Column(
          children: [
            for (final e in entries)
              _ExportHistoryTile(
                entry: e,
                onShare: () => _shareEntry(context, e),
                onDelete: () => _deleteEntry(context, e),
              ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: Spacing.lg),
              child: Align(
                alignment: Alignment.centerRight,
                child: TextButton.icon(
                  icon: const Icon(Icons.delete_sweep_outlined),
                  label: const Text('Clear all'),
                  onPressed: () => _clearAll(context),
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  Future<void> _shareEntry(
    BuildContext context,
    ExportHistoryEntry e,
  ) async {
    final file = File(e.path);
    if (!file.existsSync()) {
      UserFeedback.error(context, 'File no longer available.');
      return;
    }
    Haptics.tap();
    await Share.shareXFiles(
      [XFile(e.path, mimeType: e.format.mimeType)],
      text: 'Re-shared from Image Editor',
    );
  }

  Future<void> _deleteEntry(
    BuildContext context,
    ExportHistoryEntry e,
  ) async {
    Haptics.tap();
    await ExportHistory().remove(e.path);
    // Best-effort temp-file cleanup so the disk doesn't keep growing
    // even when the user explicitly forgets a row.
    try {
      final f = File(e.path);
      if (await f.exists()) await f.delete();
    } catch (_) {}
    // Force a re-fetch and await so the user doesn't see a stale row
    // if they delete + scroll rapidly. `refresh` returns the new
    // value; we don't need the body, just the timing.
    // ignore: unused_result
    await ref.refresh(exportHistoryProvider.future);
  }

  Future<void> _clearAll(BuildContext context) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Clear export history?'),
        content: const Text(
          'This forgets the list of recent exports. The actual files '
          'are also removed from temporary storage; copies you saved '
          'to Photos / Files stay where you put them.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton.tonal(
            style: FilledButton.styleFrom(
              foregroundColor: Theme.of(ctx).colorScheme.error,
            ),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Clear'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    final history = ExportHistory();
    final all = await history.list();
    for (final entry in all) {
      try {
        final f = File(entry.path);
        if (await f.exists()) await f.delete();
      } catch (_) {}
    }
    await history.clear();
    ref.invalidate(exportHistoryProvider);
    if (!context.mounted) return;
    UserFeedback.info(context, 'Export history cleared');
  }
}

class _ExportHistoryTile extends StatelessWidget {
  const _ExportHistoryTile({
    required this.entry,
    required this.onShare,
    required this.onDelete,
  });

  final ExportHistoryEntry entry;
  final VoidCallback onShare;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final exists = File(entry.path).existsSync();
    return ListTile(
      leading: CircleAvatar(
        backgroundColor: theme.colorScheme.primaryContainer,
        child: Text(
          entry.format.label,
          style: TextStyle(
            color: theme.colorScheme.onPrimaryContainer,
            fontSize: 10,
            fontWeight: FontWeight.w700,
          ),
        ),
      ),
      title: Text(
        '${entry.width}×${entry.height}',
        style: theme.textTheme.bodyMedium?.copyWith(
          fontFeatures: const [FontFeature.tabularFigures()],
        ),
      ),
      subtitle: Text(
        '${_kbDisplay(entry.bytes)} · ${_relative(entry.exportedAt)}'
        '${exists ? "" : " · file missing"}',
        style: theme.textTheme.bodySmall?.copyWith(
          color: exists
              ? theme.colorScheme.onSurfaceVariant
              : theme.colorScheme.error,
        ),
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            tooltip: exists ? 'Re-share' : 'File no longer available',
            icon: const Icon(Icons.ios_share),
            onPressed: exists ? onShare : null,
          ),
          IconButton(
            tooltip: 'Forget',
            icon: const Icon(Icons.delete_outline),
            onPressed: onDelete,
          ),
        ],
      ),
    );
  }

  static String _kbDisplay(int bytes) {
    if (bytes < 1024) return '$bytes B';
    final kb = bytes / 1024;
    if (kb < 1024) return '${kb.toStringAsFixed(0)} KB';
    final mb = kb / 1024;
    return '${mb.toStringAsFixed(mb < 10 ? 1 : 0)} MB';
  }

  static String _relative(DateTime ts) {
    final delta = DateTime.now().difference(ts);
    if (delta.inSeconds < 60) return 'just now';
    if (delta.inMinutes < 60) return '${delta.inMinutes}m ago';
    if (delta.inHours < 24) return '${delta.inHours}h ago';
    if (delta.inDays < 7) return '${delta.inDays}d ago';
    return '${delta.inDays ~/ 7}w ago';
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader(this.label);
  final String label;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        Spacing.lg,
        Spacing.lg,
        Spacing.lg,
        Spacing.xs,
      ),
      child: Text(
        label.toUpperCase(),
        style: theme.textTheme.labelSmall?.copyWith(
          color: theme.colorScheme.primary,
          letterSpacing: 1.2,
        ),
      ),
    );
  }
}
