import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app.dart';
import 'bootstrap.dart';
import 'core/theme/theme_mode_controller.dart';
import 'di/providers.dart';
import 'features/settings/presentation/pages/settings_page.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Apply the persisted log-level pref before any other code runs so
  // bootstrap's own logs already respect the user's choice.
  await hydratePersistedLogLevel();
  // Phase XI.C.4 — read the saved theme before the first frame so
  // MaterialApp picks up the user's preference on frame 0 instead
  // of flashing the default dark theme for one frame.
  final initialThemeMode = await hydratePersistedThemeMode();
  final bootstrapResult = await bootstrap();
  runApp(
    ProviderScope(
      overrides: [
        bootstrapResultProvider.overrideWithValue(bootstrapResult),
        themeModeControllerProvider.overrideWith(
          (ref) => ThemeModeController(initial: initialThemeMode),
        ),
      ],
      child: const ImageEditorApp(),
    ),
  );
}
