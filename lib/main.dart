import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app.dart';
import 'bootstrap.dart';
import 'core/licenses/model_licenses.dart';
import 'core/logging/app_logger.dart';
import 'core/logging/error_handlers.dart';
import 'core/theme/theme_mode_controller.dart';
import 'di/providers.dart';
import 'features/settings/presentation/pages/settings_page.dart';

void main() {
  final log = AppLogger('Uncaught');
  // XVI.116 (D1) — run the whole startup + the app inside one zone so
  // async errors are captured. ensureInitialized() and runApp MUST live
  // in the SAME zone (here, inside the runZonedGuarded callback) or
  // Flutter throws "Zone mismatch" at startup — so do NOT hoist
  // ensureInitialized out of this closure.
  runZonedGuarded(() async {
    WidgetsFlutterBinding.ensureInitialized();
    // Install FlutterError + PlatformDispatcher handlers first, before
    // any await, so even early bootstrap failures are logged.
    installErrorHandlers(log);
    // XVI.130 (A6) — attribute the shipped ML model weights in the in-app
    // Licenses screen (Dart packages are auto-collected by LicenseRegistry;
    // raw model assets are not). Lazy — runs only when the page opens.
    registerModelLicenses();
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
  }, (error, stack) {
    // Uncaught async errors in zone-scheduled work (microtasks, timers)
    // that neither FlutterError nor PlatformDispatcher caught.
    log.e('Uncaught zone error', error: error, stackTrace: stack);
  });
}
