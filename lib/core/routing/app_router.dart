import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../features/editor/presentation/pages/editor_page.dart';
import '../../features/home/presentation/pages/home_page.dart';

/// Top-level router for the app. Phase 3 only needs two routes: the home
/// page with an image picker, and the editor page which takes a source
/// path as `extra`. Phase 12 will extend this to gallery, settings, etc.
final appRouter = GoRouter(
  initialLocation: '/',
  routes: [
    GoRoute(
      path: '/',
      builder: (context, state) => const HomePage(),
    ),
    GoRoute(
      path: '/editor',
      builder: (context, state) {
        final path = state.extra as String?;
        if (path == null || path.isEmpty) {
          return const Scaffold(
            body: Center(child: Text('No image selected')),
          );
        }
        return EditorPage(sourcePath: path);
      },
    ),
  ],
);
