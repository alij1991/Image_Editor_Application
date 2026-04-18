import 'package:flutter/material.dart' show ThemeMode;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../logging/app_logger.dart';

final _log = AppLogger('ThemeMode');

const String _kThemeModePref = 'theme_mode_v1';

/// Persisted theme-mode preference. Hydrates from SharedPreferences on
/// first read; writes back on every change. Defaults to [ThemeMode.dark]
/// to match the historical chrome of the editor.
class ThemeModeController extends StateNotifier<ThemeMode> {
  ThemeModeController() : super(ThemeMode.dark) {
    _hydrate();
  }

  Future<void> _hydrate() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_kThemeModePref);
      if (raw == null) return;
      final next = _parse(raw);
      if (next != state) {
        _log.d('hydrated', {'mode': next.name});
        state = next;
      }
    } catch (e) {
      _log.w('hydrate failed', {'error': e.toString()});
    }
  }

  Future<void> setMode(ThemeMode mode) async {
    if (mode == state) return;
    state = mode;
    _log.i('set', {'mode': mode.name});
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_kThemeModePref, mode.name);
    } catch (e) {
      _log.w('persist failed', {'error': e.toString()});
    }
  }

  /// Cycle dark → light → system → dark for a quick-toggle UI.
  Future<void> cycle() async {
    switch (state) {
      case ThemeMode.dark:
        await setMode(ThemeMode.light);
      case ThemeMode.light:
        await setMode(ThemeMode.system);
      case ThemeMode.system:
        await setMode(ThemeMode.dark);
    }
  }

  static ThemeMode _parse(String raw) {
    for (final m in ThemeMode.values) {
      if (m.name == raw) return m;
    }
    return ThemeMode.dark;
  }
}

final themeModeControllerProvider =
    StateNotifierProvider<ThemeModeController, ThemeMode>(
  (ref) => ThemeModeController(),
);
