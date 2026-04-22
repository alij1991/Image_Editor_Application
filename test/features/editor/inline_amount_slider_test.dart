import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:image_editor/engine/presets/preset.dart';
import 'package:image_editor/features/editor/presentation/notifiers/editor_session.dart';
import 'package:image_editor/features/editor/presentation/widgets/preset_strip.dart';

/// VIII.3 — always-visible preset Amount slider below the strip.
///
/// The widget is designed around a `ValueListenable<AppliedPresetRecord?>`
/// + a `ValueChanged<double>` callback so these tests can drive it
/// without standing up a full `EditorSession` + its providers.
void main() {
  const strong = Preset(
    id: 'custom.test',
    name: 'Testo',
    operations: [],
    category: 'custom',
  );

  const none = Preset(
    id: 'builtin.none',
    name: 'None',
    operations: [],
    builtIn: true,
    category: 'built-in',
  );

  Future<void> pumpSlider(
    WidgetTester tester, {
    required ValueListenable<AppliedPresetRecord?> listenable,
    required ValueChanged<double> onChanged,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: InlineAmountSlider(
            appliedPreset: listenable,
            onAmountChanged: onChanged,
          ),
        ),
      ),
    );
  }

  testWidgets('disabled + "No preset applied" caption when listenable is null',
      (tester) async {
    final notifier = ValueNotifier<AppliedPresetRecord?>(null);
    await pumpSlider(
      tester,
      listenable: notifier,
      onChanged: (_) => fail('slider must not fire when disabled'),
    );

    expect(find.text('No preset applied'), findsOneWidget);
    expect(find.text('100%'), findsOneWidget);
    final slider = tester.widget<Slider>(find.byType(Slider));
    expect(slider.onChanged, isNull,
        reason: 'null callback signals disabled state to Slider');
  });

  testWidgets('disabled when the active preset id is builtin.none',
      (tester) async {
    final notifier = ValueNotifier<AppliedPresetRecord?>(
      AppliedPresetRecord(preset: none, amount: 1.0),
    );
    await pumpSlider(
      tester,
      listenable: notifier,
      onChanged: (_) => fail('slider must not fire for builtin.none'),
    );
    final slider = tester.widget<Slider>(find.byType(Slider));
    expect(slider.onChanged, isNull);
    expect(find.text('No preset applied'), findsOneWidget);
  });

  testWidgets('enabled at 80% when a strong preset is applied',
      (tester) async {
    final notifier = ValueNotifier<AppliedPresetRecord?>(
      AppliedPresetRecord(preset: strong, amount: 0.80),
    );
    await pumpSlider(
      tester,
      listenable: notifier,
      onChanged: (_) {},
    );

    expect(find.text('Testo'), findsOneWidget);
    expect(find.text('80%'), findsOneWidget);
    final slider = tester.widget<Slider>(find.byType(Slider));
    expect(slider.value, closeTo(0.80, 1e-9));
    expect(slider.onChanged, isNotNull);
    expect(slider.min, 0.0);
    expect(slider.max, 1.5);
    expect(slider.divisions, 30);
  });

  testWidgets('drag to 100% fires onAmountChanged', (tester) async {
    final notifier = ValueNotifier<AppliedPresetRecord?>(
      AppliedPresetRecord(preset: strong, amount: 0.80),
    );
    final received = <double>[];
    await pumpSlider(
      tester,
      listenable: notifier,
      onChanged: received.add,
    );

    // Drag the slider thumb to approximately 1.0 (rightward drag).
    // The Slider converts the drag offset to its value range; we
    // only care that at least one emitted value reaches 100% or
    // beyond, proving the callback is wired live.
    final slider = find.byType(Slider);
    final box = tester.getRect(slider);
    await tester.dragFrom(
      box.centerLeft + Offset(box.width * 0.8, 0),
      const Offset(100, 0),
    );
    await tester.pump();

    expect(received, isNotEmpty,
        reason: 'drag must emit at least one amount change');
    expect(received.any((v) => v >= 1.0), isTrue,
        reason: 'drag past center should include a value ≥ 1.0');
  });

  testWidgets('switching from preset to null re-disables the slider',
      (tester) async {
    final notifier = ValueNotifier<AppliedPresetRecord?>(
      AppliedPresetRecord(preset: strong, amount: 0.80),
    );
    await pumpSlider(
      tester,
      listenable: notifier,
      onChanged: (_) {},
    );

    expect(
        tester.widget<Slider>(find.byType(Slider)).onChanged, isNotNull);

    notifier.value = null;
    await tester.pump();

    expect(
        tester.widget<Slider>(find.byType(Slider)).onChanged, isNull);
    expect(find.text('No preset applied'), findsOneWidget);
  });
}
