import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app.dart';
import 'bootstrap.dart';
import 'di/providers.dart';
import 'features/settings/presentation/pages/settings_page.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Apply the persisted log-level pref before any other code runs so
  // bootstrap's own logs already respect the user's choice.
  await hydratePersistedLogLevel();
  final bootstrapResult = await bootstrap();
  runApp(
    ProviderScope(
      overrides: [
        bootstrapResultProvider.overrideWithValue(bootstrapResult),
      ],
      child: const ImageEditorApp(),
    ),
  );
}
