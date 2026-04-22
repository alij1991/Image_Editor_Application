import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:image_editor/engine/layers/content_layer.dart';
import 'package:image_editor/engine/layers/layer_blend_mode.dart';
import 'package:image_editor/engine/layers/layer_mask.dart';
import 'package:image_editor/features/editor/presentation/widgets/layer_edit_sheet.dart';

/// VIII.1 — blend-mode picker on layers.
///
/// The UI iterates `LayerBlendMode.values` so every engine-supported
/// mode is selectable. These tests pin the two contracts the rest of
/// the app relies on:
///
/// 1. **All 13 modes render as chips** — the "engine supports it but UI
///    doesn't expose it" regression is the one we're guarding against.
/// 2. **Picking a chip updates the draft layer's blendMode** — both via
///    the live `onPreview` stream and via the `Save` return value.
void main() {
  Future<void> pumpSheet(
    WidgetTester tester, {
    required ContentLayer layer,
    required ValueChanged<ContentLayer> onPreview,
    required VoidCallback onCancel,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => Center(
              child: ElevatedButton(
                onPressed: () => LayerEditSheet.show(
                  context,
                  layer: layer,
                  onPreview: onPreview,
                  onCancel: onCancel,
                ),
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

  testWidgets('renders a ChoiceChip for every LayerBlendMode', (tester) async {
    const layer = TextLayer(
      id: 'l1',
      text: 'hi',
      fontSize: 48,
      colorArgb: 0xFFFFFFFF,
    );
    await pumpSheet(
      tester,
      layer: layer,
      onPreview: (_) {},
      onCancel: () {},
    );

    for (final mode in LayerBlendMode.values) {
      expect(
        find.widgetWithText(ChoiceChip, mode.label),
        findsOneWidget,
        reason: 'missing chip for ${mode.name}',
      );
    }
  });

  testWidgets('tapping Multiply emits preview + returns draft with multiply',
      (tester) async {
    const layer = TextLayer(
      id: 'l1',
      text: 'hi',
      fontSize: 48,
      colorArgb: 0xFFFFFFFF,
    );
    final previews = <ContentLayer>[];
    ContentLayer? popped;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => Center(
              child: ElevatedButton(
                onPressed: () async {
                  popped = await LayerEditSheet.show(
                    context,
                    layer: layer,
                    onPreview: previews.add,
                    onCancel: () {},
                  );
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

    await tester.tap(find.widgetWithText(ChoiceChip, 'Multiply'));
    await tester.pump();

    expect(previews, isNotEmpty);
    expect(previews.last.blendMode, LayerBlendMode.multiply);

    await tester.tap(find.widgetWithText(FilledButton, 'Save'));
    await tester.pumpAndSettle();

    expect(popped, isNotNull);
    expect(popped!.blendMode, LayerBlendMode.multiply);
    expect(popped!.id, 'l1');
  });

  testWidgets('cancel reverts preview without a commit', (tester) async {
    const layer = StickerLayer(
      id: 's1',
      character: '\u2605',
      fontSize: 60,
      blendMode: LayerBlendMode.normal,
      mask: LayerMask(shape: MaskShape.none),
    );
    var cancelFired = false;
    ContentLayer? popped;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => Center(
              child: ElevatedButton(
                onPressed: () async {
                  popped = await LayerEditSheet.show(
                    context,
                    layer: layer,
                    onPreview: (_) {},
                    onCancel: () => cancelFired = true,
                  );
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

    await tester.tap(find.widgetWithText(ChoiceChip, 'Screen'));
    await tester.pump();

    await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
    await tester.pumpAndSettle();

    expect(cancelFired, isTrue);
    expect(popped, isNull);
  });
}
