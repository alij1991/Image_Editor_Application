import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:logger/logger.dart' show Level;
import 'package:shared_preferences/shared_preferences.dart';

import '../../../../core/feedback/user_feedback.dart';
import '../../../../core/logging/app_logger.dart';
import '../../../../core/platform/haptics.dart';
import '../../../../core/theme/spacing.dart';
import '../../../../core/theme/theme_mode_controller.dart';
import '../widgets/model_manager_sheet.dart';

final _log = AppLogger('SettingsPage');

const String _kPerfHudPref = 'perf_hud_enabled_v1';
const String _kLogLevelPref = 'log_level_v1';

/// Persisted toggle for the dev-mode performance HUD overlay. Off by
/// default — the HUD is suppressed in release builds anyway, but
/// debug-build users can disable it from here when they want a clean
/// canvas for screenshots.
final perfHudEnabledProvider =
    StateNotifierProvider<_BoolPrefController, bool>(
  (ref) => _BoolPrefController(prefKey: _kPerfHudPref, fallback: true),
);

class _BoolPrefController extends StateNotifier<bool> {
  _BoolPrefController({required this.prefKey, required this.fallback})
      : super(fallback) {
    _hydrate();
  }

  final String prefKey;
  final bool fallback;

  Future<void> _hydrate() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final v = prefs.getBool(prefKey);
      if (v != null && v != state) state = v;
    } catch (_) {}
  }

  Future<void> set(bool v) async {
    state = v;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(prefKey, v);
    } catch (e) {
      _log.w('persist failed', {'key': prefKey, 'error': e.toString()});
    }
  }
}

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
