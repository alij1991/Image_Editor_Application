import 'package:flutter/material.dart' show ThemeMode;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../logging/app_logger.dart';

final _log = AppLogger('ThemeMode');

const String _kThemeModePref = 'theme_mode_v1';

/// Persisted theme-mode preference. Writes back on every change.
///
/// The preferred way to seed state is [initial], resolved in `main()`
/// via [hydratePersistedThemeMode] before `runApp`. Passing the
/// resolved value avoids the one-frame default-dark → persisted-light
/// flash users saw on boot before Phase XI.C.4. The in-constructor
/// [_hydrate] remains as a belt-and-suspenders so callers that
/// construct the controller without going through `main()` (tests,
/// non-prod entry points) still converge on the saved mode within a
/// frame.
class ThemeModeController extends StateNotifier<ThemeMode> {
  ThemeModeController({ThemeMode initial = ThemeMode.dark}) : super(initial) {
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

/// Phase XI.C.4 — synchronously resolve the persisted theme mode
/// before the first frame. Call from `main()` and hand the result to
/// [ThemeModeController] via a [ProviderScope] override so the
/// initial render uses the saved mode — no one-frame dark flash.
///
/// Returns [ThemeMode.dark] when nothing's saved, the prefs read
/// fails, or the saved value doesn't round-trip to a known enum.
Future<ThemeMode> hydratePersistedThemeMode() async {
  try {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_kThemeModePref);
    if (raw == null) return ThemeMode.dark;
    return ThemeModeController._parse(raw);
  } catch (e) {
    _log.w('initial hydrate failed', {'error': e.toString()});
    return ThemeMode.dark;
  }
}
