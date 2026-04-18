import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:image_editor/di/providers.dart';
import 'package:image_editor/features/home/presentation/pages/home_page.dart';

import 'test_support/fake_bootstrap.dart';

void main() {
  testWidgets('Home page renders with picker CTAs and hints', (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          bootstrapResultProvider.overrideWithValue(buildFakeBootstrap()),
        ],
        child: const MaterialApp(home: HomePage()),
      ),
    );
    // Primary CTA tiles + camera shortcut are visible.
    expect(find.text('Edit photo'), findsOneWidget);
    expect(find.text('Scan document'), findsOneWidget);
    expect(find.text('Make collage'), findsOneWidget);
    expect(find.text('Take a photo'), findsOneWidget);
    // Quick tips card is present.
    expect(find.text('Quick tips'), findsOneWidget);
  });
}
