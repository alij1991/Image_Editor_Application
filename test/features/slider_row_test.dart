import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:image_editor/features/editor/presentation/widgets/slider_row.dart';

/// Widget tests for [SliderRow]. The interesting behaviour is the
/// snap-to-identity detent introduced in the slider-feel pass — when
/// the drag value is within a small band of `identity`, the slider
/// should pull the value to identity exactly.
void main() {
  Future<void> pumpRow(
    WidgetTester tester, {
    required ValueChanged<double> onChanged,
    ValueChanged<double>? onChangeEnd,
    double initialValue = 0,
    double identity = 0,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SliderRow(
            label: 'Brightness',
            initialValue: initialValue,
            identity: identity,
            onChanged: onChanged,
            onChangeEnd: onChangeEnd,
          ),
        ),
      ),
    );
  }

  testWidgets('renders label and reset button', (tester) async {
    await pumpRow(tester, onChanged: (_) {});
    expect(find.text('Brightness'), findsOneWidget);
    expect(find.byIcon(Icons.restart_alt), findsOneWidget);
  });

  testWidgets('reset button restores identity and fires onChangeEnd',
      (tester) async {
    final fired = <double>[];
    final ended = <double>[];
    await pumpRow(
      tester,
      initialValue: 0.7,
      onChanged: fired.add,
      onChangeEnd: ended.add,
    );
    await tester.tap(find.byIcon(Icons.restart_alt));
    await tester.pump();
    expect(fired.last, 0.0);
    expect(ended.last, 0.0);
  });

  testWidgets('snap-to-identity pulls near-zero values to exactly 0',
      (tester) async {
    final fired = <double>[];
    await pumpRow(
      tester,
      initialValue: 0.5,
      onChanged: fired.add,
    );
    final slider = tester.widget<Slider>(find.byType(Slider));
    // Programmatically drive the slider through the snap band. A real
    // gesture would be flaky for this — we drive the onChanged
    // callback directly with a value that's well inside the 2% band.
    slider.onChanged!(0.005);
    await tester.pump();
    expect(fired.last, 0.0,
        reason: 'value within 2% of identity should snap to identity');
  });

  testWidgets('outside the snap band the value is passed through unchanged',
      (tester) async {
    final fired = <double>[];
    await pumpRow(
      tester,
      initialValue: 0.5,
      onChanged: fired.add,
    );
    final slider = tester.widget<Slider>(find.byType(Slider));
    slider.onChanged!(0.3);
    await tester.pump();
    expect(fired.last, 0.3);
  });

  testWidgets('didUpdateWidget syncs initialValue changes', (tester) async {
    var current = 0.2;
    final controller = ValueNotifier<double>(current);
    Widget build() => MaterialApp(
          home: Scaffold(
            body: ValueListenableBuilder<double>(
              valueListenable: controller,
              builder: (_, v, _) => SliderRow(
                label: 'X',
                initialValue: v,
                onChanged: (_) {},
              ),
            ),
          ),
        );
    await tester.pumpWidget(build());
    expect(tester.widget<Slider>(find.byType(Slider)).value, 0.2);
    controller.value = -0.4;
    await tester.pump();
    expect(tester.widget<Slider>(find.byType(Slider)).value, -0.4);
    controller.dispose();
  });
}
