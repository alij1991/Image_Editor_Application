import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:image_editor/engine/layers/content_layer.dart';
import 'package:image_editor/engine/layers/layer_mask.dart';
import 'package:image_editor/features/editor/presentation/widgets/layer_painter.dart';

/// Phase VI.3 — gradient cache contract for [LayerPainter].
///
/// Drawing-heavy sessions (DrawingLayer strokes, or any paint cascade
/// that doesn't change a stable mask) used to rebuild the identical
/// `ui.Gradient.linear`/`ui.Gradient.radial` shader every frame. The
/// cache short-circuits this by keying on `LayerMask.cacheKey` +
/// rounded canvas size; this suite pins every observable edge of that
/// contract: key stability, parameter sensitivity, size sensitivity,
/// LRU capacity, and the `@visibleForTesting` counters the suite
/// relies on.
///
/// We drive the painter through a real `PictureRecorder` canvas at a
/// fixed size so the `_applyGradientMask` code path runs end-to-end;
/// the cache is shared statically across tests so each test resets it
/// in `setUp`.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(LayerPainter.debugResetGradientCache);

  void paint(LayerPainter painter, ui.Size size) {
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    painter.paint(canvas, size);
    final picture = recorder.endRecording();
    picture.dispose();
  }

  StickerLayer stickerWithMask(LayerMask mask) {
    return StickerLayer(
      id: 'mask-host',
      character: '.',
      fontSize: 16,
      x: 0.5,
      y: 0.5,
      mask: mask,
    );
  }

  group('LayerMask.cacheKey', () {
    test('none masks share the same key', () {
      expect(LayerMask.none.cacheKey, 'none');
      expect(
        const LayerMask(shape: MaskShape.none).cacheKey,
        LayerMask.none.cacheKey,
      );
    });

    test('linear and radial shapes never collide', () {
      const linear = LayerMask(
        shape: MaskShape.linear,
        cx: 0.3,
        cy: 0.4,
        angle: 1.2,
        feather: 0.5,
      );
      const radial = LayerMask(
        shape: MaskShape.radial,
        cx: 0.3,
        cy: 0.4,
        innerRadius: 0.1,
        outerRadius: 0.5,
      );
      expect(linear.cacheKey, isNot(equals(radial.cacheKey)));
    });

    test('linear key ignores radial-only params', () {
      const a = LayerMask(shape: MaskShape.linear, innerRadius: 0.1);
      const b = LayerMask(shape: MaskShape.linear, innerRadius: 0.9);
      expect(a.cacheKey, b.cacheKey);
    });

    test('radial key ignores feather and angle', () {
      const a = LayerMask(
        shape: MaskShape.radial,
        feather: 0.1,
        angle: 0.5,
      );
      const b = LayerMask(
        shape: MaskShape.radial,
        feather: 0.9,
        angle: 1.5,
      );
      expect(a.cacheKey, b.cacheKey);
    });

    test('inverted flag flips the key for both shapes', () {
      const lin = LayerMask(shape: MaskShape.linear);
      const linInv = LayerMask(shape: MaskShape.linear, inverted: true);
      expect(lin.cacheKey, isNot(equals(linInv.cacheKey)));

      const rad = LayerMask(shape: MaskShape.radial);
      const radInv = LayerMask(shape: MaskShape.radial, inverted: true);
      expect(rad.cacheKey, isNot(equals(radInv.cacheKey)));
    });
  });

  group('LayerPainter gradient cache', () {
    test('first paint misses, second paint hits (stable mask)', () {
      const mask = LayerMask(
        shape: MaskShape.linear,
        cx: 0.5,
        cy: 0.5,
        angle: 0.0,
        feather: 0.4,
      );
      final painter = LayerPainter(layers: [stickerWithMask(mask)]);
      const size = ui.Size(200, 200);

      expect(LayerPainter.debugGradientCacheMisses, 0);
      expect(LayerPainter.debugGradientCacheHits, 0);

      paint(painter, size);
      expect(LayerPainter.debugGradientCacheMisses, 1);
      expect(LayerPainter.debugGradientCacheHits, 0);
      expect(LayerPainter.debugGradientCacheSize, 1);

      paint(painter, size);
      expect(LayerPainter.debugGradientCacheMisses, 1);
      expect(LayerPainter.debugGradientCacheHits, 1);
      expect(LayerPainter.debugGradientCacheSize, 1);
    });

    test('1000 repeat paints of an unchanged mask stay at 1 miss', () {
      const mask = LayerMask(
        shape: MaskShape.radial,
        cx: 0.4,
        cy: 0.6,
        innerRadius: 0.1,
        outerRadius: 0.7,
      );
      final painter = LayerPainter(layers: [stickerWithMask(mask)]);
      const size = ui.Size(480, 320);

      for (int i = 0; i < 1000; i++) {
        paint(painter, size);
      }
      expect(LayerPainter.debugGradientCacheMisses, 1);
      expect(LayerPainter.debugGradientCacheHits, 999);
    });

    test('mask mutation (feather change) invalidates the cache', () {
      const baseMask = LayerMask(
        shape: MaskShape.linear,
        feather: 0.2,
      );
      paint(
        LayerPainter(layers: [stickerWithMask(baseMask)]),
        const ui.Size(300, 300),
      );
      expect(LayerPainter.debugGradientCacheMisses, 1);

      // Different feather → different cacheKey → new miss.
      final mutated = baseMask.copyWith(feather: 0.5);
      paint(
        LayerPainter(layers: [stickerWithMask(mutated)]),
        const ui.Size(300, 300),
      );
      expect(LayerPainter.debugGradientCacheMisses, 2);
      expect(LayerPainter.debugGradientCacheSize, 2);
    });

    test('canvas resize invalidates the cache', () {
      const mask = LayerMask(
        shape: MaskShape.linear,
        cx: 0.5,
        cy: 0.5,
      );
      final painter = LayerPainter(layers: [stickerWithMask(mask)]);

      paint(painter, const ui.Size(200, 200));
      expect(LayerPainter.debugGradientCacheMisses, 1);

      // Different size → different key → second miss.
      paint(painter, const ui.Size(400, 400));
      expect(LayerPainter.debugGradientCacheMisses, 2);
      expect(LayerPainter.debugGradientCacheSize, 2);

      // Reverting to the original size hits the original entry.
      paint(painter, const ui.Size(200, 200));
      expect(LayerPainter.debugGradientCacheMisses, 2);
      expect(LayerPainter.debugGradientCacheHits, 1);
    });

    test('sub-pixel size differences round to the same cache slot', () {
      const mask = LayerMask(shape: MaskShape.linear);
      final painter = LayerPainter(layers: [stickerWithMask(mask)]);

      paint(painter, const ui.Size(300, 300));
      expect(LayerPainter.debugGradientCacheMisses, 1);

      // Layout rounding may produce 300.2 or 299.8 in practice —
      // those should not all force new cache slots.
      paint(painter, const ui.Size(300.2, 300.2));
      paint(painter, const ui.Size(299.8, 299.8));
      expect(LayerPainter.debugGradientCacheMisses, 1);
      expect(LayerPainter.debugGradientCacheHits, 2);
    });

    test('LayerMask.none short-circuits before the cache', () {
      final painter = LayerPainter(
        layers: [stickerWithMask(LayerMask.none)],
      );
      paint(painter, const ui.Size(200, 200));
      expect(LayerPainter.debugGradientCacheMisses, 0);
      expect(LayerPainter.debugGradientCacheHits, 0);
      expect(LayerPainter.debugGradientCacheSize, 0);
    });

    test('LRU capacity: 17th unique mask evicts the oldest', () {
      // Capacity is 16 (private); walk 17 distinct masks and verify
      // cache size caps at 16 + the very first insertion is gone.
      const size = ui.Size(200, 200);
      const firstMask = LayerMask(
        shape: MaskShape.radial,
        innerRadius: 0.01,
        outerRadius: 0.1,
      );
      paint(
        LayerPainter(layers: [stickerWithMask(firstMask)]),
        size,
      );
      expect(LayerPainter.debugGradientCacheSize, 1);

      for (int i = 1; i < 17; i++) {
        final mask = LayerMask(
          shape: MaskShape.radial,
          innerRadius: 0.01 * (i + 1),
          outerRadius: 0.1 + 0.01 * i,
        );
        paint(
          LayerPainter(layers: [stickerWithMask(mask)]),
          size,
        );
      }
      // 17 unique cacheKeys, capacity 16.
      expect(LayerPainter.debugGradientCacheSize, 16);

      // Re-paint the FIRST mask — it was evicted, so a miss lands.
      final missesBefore = LayerPainter.debugGradientCacheMisses;
      paint(
        LayerPainter(layers: [stickerWithMask(firstMask)]),
        size,
      );
      expect(LayerPainter.debugGradientCacheMisses, missesBefore + 1);
    });

    test('recently-used entries survive eviction (MRU semantics)', () {
      const size = ui.Size(200, 200);
      const survivor = LayerMask(
        shape: MaskShape.radial,
        innerRadius: 0.05,
        outerRadius: 0.2,
      );

      // Prime cache with survivor + 15 others (size = 16).
      paint(
        LayerPainter(layers: [stickerWithMask(survivor)]),
        size,
      );
      for (int i = 0; i < 15; i++) {
        final mask = LayerMask(
          shape: MaskShape.radial,
          innerRadius: 0.05 + 0.01 * (i + 1),
          outerRadius: 0.2 + 0.01 * (i + 1),
        );
        paint(
          LayerPainter(layers: [stickerWithMask(mask)]),
          size,
        );
      }
      expect(LayerPainter.debugGradientCacheSize, 16);

      // Touch the survivor so it's promoted to MRU.
      paint(
        LayerPainter(layers: [stickerWithMask(survivor)]),
        size,
      );

      // Insert a fresh mask — should evict the OLDEST non-survivor,
      // not the survivor.
      const fresh = LayerMask(
        shape: MaskShape.radial,
        innerRadius: 0.9,
        outerRadius: 0.95,
      );
      paint(
        LayerPainter(layers: [stickerWithMask(fresh)]),
        size,
      );
      expect(LayerPainter.debugGradientCacheSize, 16);

      // Survivor still hits.
      final hitsBefore = LayerPainter.debugGradientCacheHits;
      paint(
        LayerPainter(layers: [stickerWithMask(survivor)]),
        size,
      );
      expect(LayerPainter.debugGradientCacheHits, hitsBefore + 1);
    });

    test('debugResetGradientCache zeroes counters and clears entries', () {
      const mask = LayerMask(shape: MaskShape.linear);
      paint(
        LayerPainter(layers: [stickerWithMask(mask)]),
        const ui.Size(100, 100),
      );
      expect(LayerPainter.debugGradientCacheMisses, 1);
      expect(LayerPainter.debugGradientCacheSize, 1);

      LayerPainter.debugResetGradientCache();
      expect(LayerPainter.debugGradientCacheMisses, 0);
      expect(LayerPainter.debugGradientCacheHits, 0);
      expect(LayerPainter.debugGradientCacheSize, 0);
    });

    test('identity mask on layer skips gradient path entirely', () {
      // Layer with no mask, no opacity, no blend — painter should
      // never call _applyGradientMask and the cache stays empty.
      final painter = LayerPainter(
        layers: const [
          StickerLayer(
            id: 's',
            character: '.',
            fontSize: 16,
            x: 0.5,
            y: 0.5,
            // mask omitted → LayerMask.none default.
          ),
        ],
      );
      paint(painter, const ui.Size(200, 200));
      expect(LayerPainter.debugGradientCacheMisses, 0);
      expect(LayerPainter.debugGradientCacheSize, 0);
    });
  });
}
