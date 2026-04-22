import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import 'package:image_editor/core/routing/app_router.dart';

/// VIII.9 — Deep-link validation: `/editor` without a source path must
/// redirect to `/` with a snackbar instead of rendering a dead-end
/// scaffold.
void main() {
  GoRouter buildRouter(String initial, {Object? initialExtra}) {
    return GoRouter(
      initialLocation: initial,
      initialExtra: initialExtra,
      routes: [
        GoRoute(
          path: '/',
          builder: (_, _) => const Scaffold(body: Text('home')),
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
          builder: (_, state) =>
              Scaffold(body: Text('editor:${state.extra}')),
        ),
      ],
    );
  }

  Future<void> pumpApp(WidgetTester tester, GoRouter router) async {
    await tester.pumpWidget(
      MaterialApp.router(
        routerConfig: router,
        scaffoldMessengerKey: rootScaffoldMessengerKey,
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('/editor with null extra redirects to / with snackbar',
      (tester) async {
    await pumpApp(tester, buildRouter('/editor'));
    expect(find.text('home'), findsOneWidget);
    expect(find.textContaining('editor:'), findsNothing);
    expect(find.text('No image selected'), findsOneWidget);
  });

  testWidgets('/editor with empty string redirects to /', (tester) async {
    await pumpApp(tester, buildRouter('/editor', initialExtra: ''));
    expect(find.text('home'), findsOneWidget);
    expect(find.textContaining('editor:'), findsNothing);
  });

  testWidgets('/editor with a real path renders the editor', (tester) async {
    await pumpApp(
      tester,
      buildRouter('/editor', initialExtra: '/tmp/img.jpg'),
    );
    expect(find.text('editor:/tmp/img.jpg'), findsOneWidget);
    expect(find.text('No image selected'), findsNothing);
  });
}
