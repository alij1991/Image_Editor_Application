import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:image_editor/features/editor/presentation/widgets/sticker_picker_sheet.dart';

/// Widget tests for [StickerPickerSheet]. The sticker catalogue lives
/// inside the file as private data; we exercise the UI surface
/// (search field, tab bar, tile taps) instead of asserting specific
/// emoji indexes.
void main() {
  Future<void> pumpSheet(WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => Center(
              child: ElevatedButton(
                onPressed: () => StickerPickerSheet.show(context, id: 'test-id'),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  testWidgets('renders search field, tab bar, and category tabs',
      (tester) async {
    await pumpSheet(tester);
    expect(find.byType(TextField), findsOneWidget);
    expect(find.byType(TabBar), findsOneWidget);
    // At least the canonical categories live in the tab bar.
    expect(find.text('Smileys'), findsOneWidget);
    expect(find.text('Hearts'), findsOneWidget);
    expect(find.text('Animals'), findsOneWidget);
    expect(find.text('Travel'), findsOneWidget);
  });

  testWidgets('typing into the search field hides the tab bar',
      (tester) async {
    await pumpSheet(tester);
    expect(find.byType(TabBar), findsOneWidget);
    await tester.enterText(find.byType(TextField), 'heart');
    await tester.pump();
    expect(find.byType(TabBar), findsNothing);
  });

  testWidgets('search with no matches shows a friendly empty state',
      (tester) async {
    await pumpSheet(tester);
    await tester.enterText(find.byType(TextField), 'xyzqq_no_tag_matches_this');
    await tester.pump();
    expect(find.byIcon(Icons.search_off), findsOneWidget);
    expect(find.textContaining('No matches'), findsOneWidget);
  });

  testWidgets('clear (close) icon resets the query and brings tabs back',
      (tester) async {
    await pumpSheet(tester);
    await tester.enterText(find.byType(TextField), 'fire');
    await tester.pump();
    expect(find.byType(TabBar), findsNothing);
    // The suffix close icon appears only when the query is non-empty.
    final closeIcon = find.descendant(
      of: find.byType(TextField),
      matching: find.byIcon(Icons.close),
    );
    expect(closeIcon, findsOneWidget);
    await tester.tap(closeIcon);
    await tester.pumpAndSettle();
    expect(find.byType(TabBar), findsOneWidget);
  });

  testWidgets('cancel button pops without picking', (tester) async {
    await pumpSheet(tester);
    final cancelBtn = find.descendant(
      of: find.byType(IconButton),
      matching: find.byIcon(Icons.close),
    );
    expect(cancelBtn, findsWidgets);
    // Tap the first close icon (the app-bar style cancel).
    await tester.tap(cancelBtn.first);
    await tester.pumpAndSettle();
    // Sheet popped → the trigger button is back.
    expect(find.text('open'), findsOneWidget);
  });
}
