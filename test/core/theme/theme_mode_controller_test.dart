import 'package:flutter/material.dart' show ThemeMode;
import 'package:flutter_test/flutter_test.dart';
import 'package:image_editor/core/theme/theme_mode_controller.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Phase XI.C.4: boot-time hydration avoids the one-frame dark flash
/// for users whose saved theme is light or system.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('hydratePersistedThemeMode (Phase XI.C.4)', () {
    setUp(() {
      SharedPreferences.setMockInitialValues({});
    });

    test('returns dark when no saved preference', () async {
      final mode = await hydratePersistedThemeMode();
      expect(mode, ThemeMode.dark);
    });

    test('returns light when saved', () async {
      SharedPreferences.setMockInitialValues({
        'theme_mode_v1': 'light',
      });
      final mode = await hydratePersistedThemeMode();
      expect(mode, ThemeMode.light);
    });

    test('returns system when saved', () async {
      SharedPreferences.setMockInitialValues({
        'theme_mode_v1': 'system',
      });
      final mode = await hydratePersistedThemeMode();
      expect(mode, ThemeMode.system);
    });

    test('returns dark on unrecognized value', () async {
      SharedPreferences.setMockInitialValues({
        'theme_mode_v1': 'banana',
      });
      final mode = await hydratePersistedThemeMode();
      expect(mode, ThemeMode.dark);
    });
  });

  group('ThemeModeController initial seed (Phase XI.C.4)', () {
    setUp(() {
      SharedPreferences.setMockInitialValues({});
    });

    test('defaults to dark when no initial supplied', () {
      final controller = ThemeModeController();
      expect(controller.state, ThemeMode.dark);
    });

    test('starts at the provided initial mode', () {
      final controller = ThemeModeController(initial: ThemeMode.light);
      expect(controller.state, ThemeMode.light,
          reason: 'first frame must see the hydrated mode, not dark');
    });

    test('provided initial matches the pref — no flash-then-swap', () async {
      // Simulates the main() path: pref is "light", main reads it via
      // hydratePersistedThemeMode(), passes it as `initial`. The
      // controller's own _hydrate() re-reads the same pref and
      // converges on the same value — no intermediate state flip.
      SharedPreferences.setMockInitialValues({
        'theme_mode_v1': 'light',
      });
      final initial = await hydratePersistedThemeMode();
      final controller = ThemeModeController(initial: initial);
      expect(controller.state, ThemeMode.light);
      // Let the constructor's internal _hydrate complete.
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(controller.state, ThemeMode.light,
          reason: '_hydrate must be a no-op when initial already matches');
    });
  });
}
