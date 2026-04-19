import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'core/routing/app_router.dart';
import 'core/theme/app_theme.dart';
import 'core/theme/theme_mode_controller.dart';

/// Root widget for the image editor.
class ImageEditorApp extends ConsumerWidget {
  const ImageEditorApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Theme mode persists across launches via ThemeModeController. The
    // default is [ThemeMode.dark] so existing users keep the editor
    // chrome they're used to; first-time toggle from the home page's
    // About dialog flips between dark / light / system.
    final themeMode = ref.watch(themeModeControllerProvider);
    return MaterialApp.router(
      title: 'Image Editor',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light(),
      darkTheme: AppTheme.dark(),
      themeMode: themeMode,
      routerConfig: appRouter,
    );
  }
}
