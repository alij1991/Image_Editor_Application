import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:logger/logger.dart' show Level;
import 'package:shared_preferences/shared_preferences.dart';

import 'package:image_editor/core/logging/app_logger.dart';
import 'package:image_editor/features/settings/presentation/pages/settings_page.dart';

/// Widget tests for the consolidated SettingsPage. The page touches
/// SharedPreferences (theme + perf HUD + log level), so each test
/// resets the in-memory mock to a clean state and gives the State
/// notifiers a microtask to hydrate.
void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  Future<void> pumpSettings(WidgetTester tester) async {
    await tester.pumpWidget(
      const ProviderScope(
        child: MaterialApp(home: SettingsPage()),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('renders all section headers', (tester) async {
    await pumpSettings(tester);
    expect(find.text('APPEARANCE'), findsOneWidget);
    expect(find.text('AI'), findsOneWidget);
    expect(find.text('DIAGNOSTICS'), findsOneWidget);
    expect(find.text('ABOUT'), findsOneWidget);
  });

  testWidgets('theme segmented buttons reflect current mode', (tester) async {
    await pumpSettings(tester);
    expect(find.byType(SegmentedButton<ThemeMode>), findsOneWidget);
  });

  testWidgets('selecting a theme segment persists the choice',
      (tester) async {
    await pumpSettings(tester);
    // Tap the light icon (first segment).
    await tester.tap(find.byIcon(Icons.light_mode));
    await tester.pumpAndSettle();
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('theme_mode_v1'), 'light');
  });

  testWidgets('perf HUD switch toggles and persists', (tester) async {
    await pumpSettings(tester);
    final switchFinder = find.byType(SwitchListTile);
    expect(switchFinder, findsOneWidget);
    final initial = (tester.widget(switchFinder) as SwitchListTile).value;
    await tester.tap(switchFinder);
    await tester.pumpAndSettle();
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool('perf_hud_enabled_v1'), !initial);
  });

  testWidgets('log level dropdown persists the choice', (tester) async {
    await pumpSettings(tester);
    // Open the dropdown and pick Warning.
    await tester.tap(find.byType(DropdownButton<Level>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Warning').last);
    await tester.pumpAndSettle();
    expect(AppLogger.level, Level.warning);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('log_level_v1'), 'warning');
  });

  testWidgets('hydratePersistedLogLevel applies the saved value',
      (tester) async {
    SharedPreferences.setMockInitialValues({'log_level_v1': 'error'});
    AppLogger.level = Level.debug;
    await hydratePersistedLogLevel();
    expect(AppLogger.level, Level.error);
  });
}
