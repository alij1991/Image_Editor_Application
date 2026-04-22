import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:image_editor/features/collage/presentation/pages/collage_page.dart';

/// VIII.6 — collage export sheet's resolution picker.
///
/// Exporter already supports the pixelRatio parameter; this picker
/// surfaces three sensible presets so the user can opt up to 8×
/// without code changes.
void main() {
  Future<double?> openAndPick(
    WidgetTester tester,
    String? optionName,
  ) async {
    double? result;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: TextButton(
                onPressed: () async {
                  result = await showCollageResolutionPicker(context);
                },
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    if (optionName == null) {
      // Dismiss without picking — tap outside the sheet.
      await tester.tapAt(const Offset(20, 20));
      await tester.pumpAndSettle();
      return result;
    }
    await tester.tap(find.byKey(Key('collage-res.$optionName')));
    await tester.pumpAndSettle();
    return result;
  }

  test('CollageResolution enum exposes 3, 5, 8 pixel ratios', () {
    expect(CollageResolution.standard.pixelRatio, 3.0);
    expect(CollageResolution.high.pixelRatio, 5.0);
    expect(CollageResolution.maximum.pixelRatio, 8.0);
  });

  testWidgets('renders all three options with labels', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => showCollageResolutionPicker(context),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(find.text('Standard'), findsOneWidget);
    expect(find.text('High'), findsOneWidget);
    expect(find.text('Maximum'), findsOneWidget);
    expect(find.text('3×'), findsOneWidget);
    expect(find.text('5×'), findsOneWidget);
    expect(find.text('8×'), findsOneWidget);
  });

  testWidgets('picking Maximum returns 8.0', (tester) async {
    final ratio = await openAndPick(tester, 'maximum');
    expect(ratio, 8.0);
  });

  testWidgets('picking Standard returns 3.0', (tester) async {
    final ratio = await openAndPick(tester, 'standard');
    expect(ratio, 3.0);
  });

  testWidgets('dismiss without selecting returns null', (tester) async {
    final ratio = await openAndPick(tester, null);
    expect(ratio, isNull);
  });
}
