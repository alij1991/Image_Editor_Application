import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app.dart';
import 'bootstrap.dart';
import 'di/providers.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
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
