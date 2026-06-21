import 'package:flutter_test/flutter_test.dart';

import 'package:image_editor/features/collage/data/collage_exporter.dart';
import 'package:image_editor/features/collage/presentation/widgets/collage_canvas.dart';

/// XVI.123 (D3) — collage OOM guards. Two pure helpers cap the two
/// pressure points: per-cell decode size and export rasterise size.
void main() {
  group('collageCellCacheWidth — decode sized to the export ceiling', () {
    test('a full-bleed cell decodes at exactly the export ceiling', () {
      // cell == canvas → ratio·cell == maxOutputLongEdge. Sharp export
      // (no upscaling) at the maximum the export can produce.
      expect(
        collageCellCacheWidth(
          cellLongEdge: 1080,
          canvasLongEdge: 1080,
          maxOutputLongEdge: 4096,
        ),
        4096,
      );
    });

    test('a 3×3 grid cell decodes at ~ceiling/3 (bounded, not full-res)', () {
      // cell ≈ canvas/3 → cacheWidth ≈ maxOutputLongEdge/3. A 20 MP
      // source (~5000 px) would otherwise decode at full ~80 MB; here
      // it's ~1366 px ≈ 7 MB.
      final w = collageCellCacheWidth(
        cellLongEdge: 360,
        canvasLongEdge: 1080,
        maxOutputLongEdge: 4096,
      );
      expect(w, (360 * 4096 / 1080).ceil()); // 1366
      expect(w, lessThan(2000));
    });

    test('never exceeds the export ceiling (cell ≤ canvas)', () {
      for (final cell in [100.0, 540.0, 1080.0]) {
        final w = collageCellCacheWidth(
          cellLongEdge: cell,
          canvasLongEdge: 1080,
          maxOutputLongEdge: 4096,
        )!;
        expect(w, lessThanOrEqualTo(4096));
      }
    });

    test('scales with the device-tier ceiling', () {
      final low = collageCellCacheWidth(
        cellLongEdge: 1080,
        canvasLongEdge: 1080,
        maxOutputLongEdge: 2880, // 1440×2 low tier
      );
      final high = collageCellCacheWidth(
        cellLongEdge: 1080,
        canvasLongEdge: 1080,
        maxOutputLongEdge: 5120, // 2560×2 high tier
      );
      expect(low, 2880);
      expect(high, 5120);
    });

    test('null for degenerate inputs so Image.file does a full decode', () {
      expect(
        collageCellCacheWidth(
            cellLongEdge: 0, canvasLongEdge: 1080, maxOutputLongEdge: 4096),
        isNull,
      );
      expect(
        collageCellCacheWidth(
            cellLongEdge: double.infinity,
            canvasLongEdge: 1080,
            maxOutputLongEdge: 4096),
        isNull,
      );
      expect(
        collageCellCacheWidth(
            cellLongEdge: 360, canvasLongEdge: 0, maxOutputLongEdge: 4096),
        isNull,
      );
      expect(
        collageCellCacheWidth(
            cellLongEdge: 360, canvasLongEdge: 1080, maxOutputLongEdge: 0),
        isNull,
      );
    });
  });

  group('effectiveCollagePixelRatio — cap export rasterise', () {
    test('caps an 8× request on a 1080-pt canvas to fit the long edge', () {
      // 8× → 8640 px (~299 MB RGBA); cap 4096 → 4096/1080 ≈ 3.79×.
      final r = effectiveCollagePixelRatio(
        requested: 8.0,
        logicalLongEdge: 1080,
        maxOutputLongEdge: 4096,
      );
      expect(r, closeTo(4096 / 1080, 1e-9));
      expect((1080 * r).round(), lessThanOrEqualTo(4096));
    });

    test('leaves a request that already fits unchanged', () {
      expect(
        effectiveCollagePixelRatio(
          requested: 3.0,
          logicalLongEdge: 1080,
          maxOutputLongEdge: 4096,
        ),
        3.0,
      );
    });

    test('device-tier ceiling scales the cap (previewLongEdge × 2)', () {
      // Low tier: previewLongEdge 1440 → cap 2880. High tier: 2560 → 5120.
      final low = effectiveCollagePixelRatio(
        requested: 8.0,
        logicalLongEdge: 1080,
        maxOutputLongEdge: 1440 * 2,
      );
      final high = effectiveCollagePixelRatio(
        requested: 8.0,
        logicalLongEdge: 1080,
        maxOutputLongEdge: 2560 * 2,
      );
      expect((1080 * low).round(), lessThanOrEqualTo(2880));
      expect((1080 * high).round(), lessThanOrEqualTo(5120));
      expect(high, greaterThan(low));
    });

    test('degenerate inputs return the request unchanged', () {
      expect(
        effectiveCollagePixelRatio(
          requested: 8.0,
          logicalLongEdge: 0,
          maxOutputLongEdge: 4096,
        ),
        8.0,
      );
      expect(
        effectiveCollagePixelRatio(
          requested: 0,
          logicalLongEdge: 1080,
          maxOutputLongEdge: 4096,
        ),
        0,
      );
    });
  });
}
