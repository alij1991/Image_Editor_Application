import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:image_editor/ai/inference/mask_components.dart';

/// Build an RGBA mask of [w]×[h] with the given painted rectangles
/// (R=255). Rects are (x, y, rw, rh).
Uint8List _maskWith(int w, int h, List<List<int>> rects) {
  final m = Uint8List(w * h * 4);
  for (final r in rects) {
    final x0 = r[0], y0 = r[1], rw = r[2], rh = r[3];
    for (var y = y0; y < y0 + rh; y++) {
      for (var x = x0; x < x0 + rw; x++) {
        final p = (y * w + x) * 4;
        m[p] = 255;
        m[p + 3] = 255;
      }
    }
  }
  return m;
}

void main() {
  group('labelMaskComponents', () {
    test('single blob → one component', () {
      final m = _maskWith(20, 20, [
        [2, 2, 5, 5],
      ]);
      final c = labelMaskComponents(m, width: 20, height: 20);
      expect(c.count, 1);
      expect(c.sizes.values.first, 25);
    });

    test('two separated blobs → two components', () {
      final m = _maskWith(30, 30, [
        [1, 1, 4, 4], // 16 px
        [20, 20, 6, 6], // 36 px
      ]);
      final c = labelMaskComponents(m, width: 30, height: 30);
      expect(c.count, 2);
      final ordered = c.labelsBySizeDesc();
      // Largest first → the 36-px blob.
      expect(c.sizes[ordered.first], 36);
      expect(c.sizes[ordered.last], 16);
    });

    test('diagonally touching blobs are SEPARATE (4-connectivity)', () {
      // Two 1px cells touching only at a corner.
      final m = Uint8List(4 * 4 * 4);
      void paint(int x, int y) {
        final p = (y * 4 + x) * 4;
        m[p] = 255;
        m[p + 3] = 255;
      }

      paint(1, 1);
      paint(2, 2);
      final c = labelMaskComponents(m, width: 4, height: 4);
      expect(c.count, 2);
    });

    test('labelsBySizeDesc drops components below minPixels', () {
      final m = _maskWith(30, 30, [
        [1, 1, 2, 2], // 4 px (noise)
        [10, 10, 6, 6], // 36 px (real)
      ]);
      final c = labelMaskComponents(m, width: 30, height: 30);
      final kept = c.labelsBySizeDesc(minPixels: 10);
      expect(kept, hasLength(1));
      expect(c.sizes[kept.first], 36);
    });

    test('empty mask → zero components', () {
      final m = Uint8List(10 * 10 * 4);
      final c = labelMaskComponents(m, width: 10, height: 10);
      expect(c.count, 0);
      expect(c.labelsBySizeDesc(), isEmpty);
    });

    test('throws on size mismatch', () {
      expect(
        () => labelMaskComponents(Uint8List(10), width: 4, height: 4),
        throwsArgumentError,
      );
    });
  });

  group('extractComponentMask', () {
    test('keeps only the target component, zeroes the rest', () {
      final m = _maskWith(30, 30, [
        [1, 1, 4, 4],
        [20, 20, 6, 6],
      ]);
      final c = labelMaskComponents(m, width: 30, height: 30);
      final ordered = c.labelsBySizeDesc(); // [big, small]
      final bigOnly = extractComponentMask(c, m, ordered.first);

      // Big blob (20,20) present.
      expect(bigOnly[(22 * 30 + 22) * 4], 255);
      // Small blob (1,1) zeroed.
      expect(bigOnly[(2 * 30 + 2) * 4], 0);
    });

    test('preserves original mask values (soft edges) for kept comp', () {
      // Paint a component with a soft edge value (R=200).
      final m = Uint8List(10 * 10 * 4);
      for (var y = 2; y < 5; y++) {
        for (var x = 2; x < 5; x++) {
          final p = (y * 10 + x) * 4;
          m[p] = 200; // still >= 128 so painted, but not 255
          m[p + 3] = 255;
        }
      }
      final c = labelMaskComponents(m, width: 10, height: 10);
      final only = extractComponentMask(c, m, c.labelsBySizeDesc().first);
      expect(only[(3 * 10 + 3) * 4], 200); // original value preserved
    });

    test('throws on source size mismatch', () {
      final m = _maskWith(10, 10, [
        [1, 1, 2, 2],
      ]);
      final c = labelMaskComponents(m, width: 10, height: 10);
      expect(
        () => extractComponentMask(c, Uint8List(8), c.labelsBySizeDesc().first),
        throwsArgumentError,
      );
    });
  });
}
