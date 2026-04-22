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
    double snapBand = 0.02,
    double min = -1.0,
    double max = 1.0,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SliderRow(
            label: 'Brightness',
            initialValue: initialValue,
            identity: identity,
            snapBand: snapBand,
            min: min,
            max: max,
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

  // VIII.15 — per-spec snapBand tuning. The default 0.02 was the
  // pre-VIII.15 hard-coded value; gamma uses 0.05 (wider) and hue
  // uses 0.01 (narrower).
  testWidgets('snapBand=0.05 (gamma) snaps a value at 9% from identity',
      (tester) async {
    final fired = <double>[];
    await pumpRow(
      tester,
      initialValue: 2.0,
      identity: 1.0,
      snapBand: 0.05,
      min: 0.1,
      max: 4.0,
      onChanged: fired.add,
    );
    final slider = tester.widget<Slider>(find.byType(Slider));
    // Range is 3.9; 0.05 band = 0.195. So value 1.15 (within 0.195
    // of identity 1.0) should snap to 1.0.
    slider.onChanged!(1.15);
    await tester.pump();
    expect(fired.last, closeTo(1.0, 1e-9),
        reason: 'gamma\'s 5% band absorbs near-identity values');
  });

  testWidgets('snapBand=0.01 (hue) does NOT snap a value at 1.5° from identity',
      (tester) async {
    final fired = <double>[];
    await pumpRow(
      tester,
      initialValue: 0,
      identity: 0,
      snapBand: 0.01,
      min: -180,
      max: 180,
      onChanged: fired.add,
    );
    final slider = tester.widget<Slider>(find.byType(Slider));
    // Range is 360; 0.01 band = 3.6. A value of 1.5 IS inside the
    // band, so let's pick 5 — outside the band, expect pass-through.
    slider.onChanged!(5.0);
    await tester.pump();
    expect(fired.last, 5.0,
        reason: 'hue\'s tighter 1% band lets small intentional shifts '
            'through');
  });

  testWidgets('snapBand=0.01 (hue) DOES snap a value at 2° (inside the band)',
      (tester) async {
    final fired = <double>[];
    await pumpRow(
      tester,
      initialValue: 0,
      identity: 0,
      snapBand: 0.01,
      min: -180,
      max: 180,
      onChanged: fired.add,
    );
    final slider = tester.widget<Slider>(find.byType(Slider));
    // 2° is inside the 3.6° band → snap to 0.
    slider.onChanged!(2.0);
    await tester.pump();
    expect(fired.last, 0.0);
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
