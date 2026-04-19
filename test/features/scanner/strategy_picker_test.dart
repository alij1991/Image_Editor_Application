import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:image_editor/features/scanner/domain/models/scan_models.dart';
import 'package:image_editor/features/scanner/presentation/widgets/strategy_picker.dart';

void main() {
  Future<void> _open(
    WidgetTester tester, {
    required DetectorStrategy recommended,
    String? nativeDisabledReason,
  }) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) => ElevatedButton(
            onPressed: () => showStrategyPicker(
              context,
              recommended: recommended,
              nativeDisabledReason: nativeDisabledReason,
            ),
            child: const Text('open'),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  testWidgets(
      'strategy picker shows the disabled reason on the Native tile',
      (tester) async {
    await _open(
      tester,
      recommended: DetectorStrategy.auto,
      nativeDisabledReason:
          'Google Play Services is missing on this device.',
    );
    expect(find.text('Native scanner'), findsOneWidget);
    expect(find.text('Unavailable'), findsOneWidget);
    expect(
      find.text('Google Play Services is missing on this device.'),
      findsOneWidget,
    );
  });

  testWidgets(
      'strategy picker leaves Native tile enabled when no reason is given',
      (tester) async {
    await _open(tester, recommended: DetectorStrategy.native);
    expect(find.text('Unavailable'), findsNothing);
    expect(find.text('Recommended'), findsOneWidget);
  });

  testWidgets('strategy picker disables the Native tile to taps', (tester) async {
    await _open(
      tester,
      recommended: DetectorStrategy.auto,
      nativeDisabledReason: 'Reason',
    );
    // Tapping the disabled tile should not pop the sheet — there's
    // still a "Recommended" badge visible on the Auto tile.
    await tester.tap(find.text('Native scanner'));
    await tester.pumpAndSettle();
    expect(find.text('Detection mode'), findsOneWidget);
  });
}
