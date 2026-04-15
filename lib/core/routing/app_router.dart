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
  ],
);
