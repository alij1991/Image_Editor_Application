import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app.dart';
import 'bootstrap.dart';
import 'di/providers.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Lock to portrait — every panel-stack layout below assumes a tall
  // viewport (canvas + preset strip + tool dock + category content).
  // Landscape squeezes the canvas to invisible on small phones; until
  // we ship a side-by-side landscape layout, lock to portrait so
  // accidental rotation doesn't strand the user. Tablet support and
  // a real landscape mode land in a follow-up.
  await SystemChrome.setPreferredOrientations([
    DeviceOrientation.portraitUp,
    DeviceOrientation.portraitDown,
  ]);
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
