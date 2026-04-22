import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../features/collage/presentation/pages/collage_page.dart';
import '../../features/editor/presentation/pages/editor_page.dart';
import '../../features/home/presentation/pages/home_page.dart';
import '../../features/scanner/presentation/pages/scanner_capture_page.dart';
import '../../features/scanner/presentation/pages/scanner_crop_page.dart';
import '../../features/scanner/presentation/pages/scanner_export_page.dart';
import '../../features/scanner/presentation/pages/scanner_history_page.dart';
import '../../features/scanner/presentation/pages/scanner_review_page.dart';
import '../../features/settings/presentation/pages/settings_page.dart';

/// Shared messenger so router-level redirects (e.g. `/editor` without a
/// source path) can surface a snackbar on the landing route without
/// waiting for a widget to resolve `ScaffoldMessenger.of(context)`.
final rootScaffoldMessengerKey = GlobalKey<ScaffoldMessengerState>();

/// Top-level router for the app. Phase 3 seeded the editor routes;
/// Phase 10 adds the document-scanner flow.
final appRouter = GoRouter(
  initialLocation: '/',
  routes: [
    GoRoute(
      path: '/',
      builder: (context, state) => const HomePage(),
    ),
    GoRoute(
      path: '/editor',
      redirect: (context, state) {
        final path = state.extra as String?;
        if (path == null || path.isEmpty) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            rootScaffoldMessengerKey.currentState?.showSnackBar(
              const SnackBar(content: Text('No image selected')),
            );
          });
          return '/';
        }
        return null;
      },
      builder: (context, state) => EditorPage(sourcePath: state.extra as String),
    ),
    GoRoute(
      path: '/scanner',
      builder: (context, state) => const ScannerCapturePage(),
    ),
    GoRoute(
      path: '/scanner/crop',
      builder: (context, state) => const ScannerCropPage(),
    ),
    GoRoute(
      path: '/scanner/review',
      builder: (context, state) => const ScannerReviewPage(),
    ),
    GoRoute(
      path: '/scanner/export',
      builder: (context, state) => const ScannerExportPage(),
    ),
    GoRoute(
      path: '/scanner/history',
      builder: (context, state) => const ScannerHistoryPage(),
    ),
    GoRoute(
      path: '/collage',
      builder: (context, state) => const CollagePage(),
    ),
    GoRoute(
      path: '/settings',
      builder: (context, state) => const SettingsPage(),
    ),
  ],
);
