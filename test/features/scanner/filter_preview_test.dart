import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:image_editor/features/scanner/domain/models/scan_models.dart';
import 'package:image_editor/features/scanner/presentation/widgets/filter_chip_row.dart';
import 'package:image_editor/features/scanner/presentation/widgets/filter_preview.dart';

/// VIII.4 — filter chip previews on the scanner review page.
///
/// `FilterPreview.matrixFor` returns a 5×4 colour-filter matrix
/// approximation of each `ScanFilter` so the chip can render a
/// thumbnail of the source image with that filter applied — without
/// running the full perspective-warp + OpenCV pipeline per chip.
///
/// `FilterChipRow` falls back to label-only chips when no source path
/// is provided (the pre-VIII.4 behaviour).
void main() {
  group('FilterPreview.matrixFor', () {
    test('every ScanFilter returns a 20-element matrix', () {
      for (final f in ScanFilter.values) {
        final m = FilterPreview.matrixFor(f);
        expect(m.length, 20, reason: 'matrix for ${f.name}');
      }
    });

    test('grayscale matrix produces a near-zero saturation row', () {
      // Saturation rows: cells [0..2] (R), [5..7] (G), [10..12] (B).
      // Grayscale should make all three rows look similar (luminance
      // mix only).
      final m = FilterPreview.matrixFor(ScanFilter.grayscale);
      for (var col = 0; col < 3; col++) {
        // R, G, B rows must agree on the column-wise coefficient
        // because saturation = 0 collapses everything to luminance.
        expect(m[col], closeTo(m[5 + col], 1e-6),
            reason: 'col $col R vs G');
        expect(m[col], closeTo(m[10 + col], 1e-6),
            reason: 'col $col R vs B');
      }
    });

    test('color matrix is more saturated than auto', () {
      final autoM = FilterPreview.matrixFor(ScanFilter.auto);
      final colorM = FilterPreview.matrixFor(ScanFilter.color);
      // Saturated matrices have larger absolute on-diagonal weights.
      expect(colorM[0].abs(), greaterThan(autoM[0].abs()));
    });

    test('magicColor warm bias makes R weight > B weight', () {
      final m = FilterPreview.matrixFor(ScanFilter.magicColor);
      expect(m[0], greaterThan(m[12]),
          reason: 'magicColor lifts the red channel above blue');
    });

    test('colorFilterFor returns a Flutter ColorFilter for every value', () {
      for (final f in ScanFilter.values) {
        expect(FilterPreview.colorFilterFor(f), isA<ColorFilter>(),
            reason: 'filter for ${f.name}');
      }
    });
  });

  group('FilterChipRow', () {
    testWidgets('renders label-only chips when sourcePath is null',
        (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: FilterChipRow(
              selected: ScanFilter.color,
              onChanged: (_) {},
            ),
          ),
        ),
      );
      // Each chip should render the filter's label.
      for (final f in ScanFilter.values) {
        expect(find.text(f.label), findsOneWidget,
            reason: 'label for ${f.name}');
      }
      // No image widgets when there's no source.
      expect(find.byType(Image), findsNothing);
    });

    testWidgets('renders preview chips with ColorFiltered when sourcePath '
        'is provided', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: FilterChipRow(
              selected: ScanFilter.color,
              onChanged: (_) {},
              sourcePath: '/tmp/missing.jpg',
            ),
          ),
        ),
      );
      // ColorFiltered shows up once per filter chip.
      final colorFilteredCount =
          tester.widgetList(find.byType(ColorFiltered)).length;
      expect(colorFilteredCount, ScanFilter.values.length,
          reason: 'one ColorFiltered per chip');
      // Labels still render below each thumbnail.
      for (final f in ScanFilter.values) {
        expect(find.text(f.label), findsOneWidget);
      }
    });

    testWidgets('tapping a preview chip fires onChanged with the filter',
        (tester) async {
      ScanFilter? picked;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: FilterChipRow(
              selected: ScanFilter.color,
              onChanged: (f) => picked = f,
              sourcePath: '/tmp/missing.jpg',
            ),
          ),
        ),
      );
      await tester.tap(find.text('Magic Color'));
      await tester.pump();
      expect(picked, ScanFilter.magicColor);
    });
  });
}
