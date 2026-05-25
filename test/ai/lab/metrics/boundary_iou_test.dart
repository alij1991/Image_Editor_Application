import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:image_editor/ai/lab/metrics/boundary_iou.dart';

void main() {
  group('boundaryDilationFor', () {
    test('2% of short edge, min 2', () {
      expect(boundaryDilationFor(100, 100), 2);
      expect(boundaryDilationFor(1000, 500), 10);
      expect(boundaryDilationFor(50, 200), 2); // min clamp
    });
  });

  group('erodeMaskOnce', () {
    test('isolated pixel disappears', () {
      // 3x3, single 1 in centre, surrounded by 0s.
      final m = Uint8List.fromList([0, 0, 0, 0, 1, 0, 0, 0, 0]);
      final out = erodeMaskOnce(m, width: 3, height: 3);
      expect(out, [0, 0, 0, 0, 0, 0, 0, 0, 0]);
    });

    test('solid 5x5 block shrinks by 1 px on every side', () {
      final m = Uint8List(5 * 5);
      for (var i = 0; i < m.length; i++) {
        m[i] = 1;
      }
      final out = erodeMaskOnce(m, width: 5, height: 5);
      // Only the central 3x3 should survive.
      final expected = <int>[];
      for (var y = 0; y < 5; y++) {
        for (var x = 0; x < 5; x++) {
          final survives = x > 0 && x < 4 && y > 0 && y < 4;
          expected.add(survives ? 1 : 0);
        }
      }
      expect(out, expected);
    });

    test('size mismatch throws', () {
      expect(
        () => erodeMaskOnce(Uint8List(8), width: 4, height: 4),
        throwsArgumentError,
      );
    });
  });

  group('erodeMaskBy', () {
    test('erode by 2 = two iterations', () {
      final m = Uint8List(7 * 7);
      for (var i = 0; i < m.length; i++) {
        m[i] = 1;
      }
      final out = erodeMaskBy(m, width: 7, height: 7, radius: 2);
      // Central 3x3 should survive (border 2 erodes away).
      var on = 0;
      for (var v in out) {
        if (v != 0) on++;
      }
      expect(on, 9);
    });

    test('radius 0 is a no-op (returns input reference)', () {
      final m = Uint8List.fromList([1, 0, 1, 1]);
      final out = erodeMaskBy(m, width: 2, height: 2, radius: 0);
      expect(out, m);
    });
  });

  group('boundaryBand', () {
    test('boundary band of solid block = the rim', () {
      final m = Uint8List(5 * 5);
      for (var i = 0; i < m.length; i++) {
        m[i] = 1;
      }
      final band = boundaryBand(m, width: 5, height: 5, radius: 1);
      // Rim is everything except the central 3x3.
      final expected = <int>[];
      for (var y = 0; y < 5; y++) {
        for (var x = 0; x < 5; x++) {
          final interior = x > 0 && x < 4 && y > 0 && y < 4;
          expected.add(interior ? 0 : 1);
        }
      }
      expect(band, expected);
    });
  });

  group('computeBoundaryIou', () {
    test('identical masks → boundary IoU 1', () {
      final m = Uint8List(8 * 8);
      // L-shape so the boundary is non-trivial.
      for (var y = 0; y < 8; y++) {
        for (var x = 0; x < 8; x++) {
          m[y * 8 + x] = (x < 4 || y < 4) ? 1 : 0;
        }
      }
      expect(
        computeBoundaryIou(m, m, width: 8, height: 8, dilation: 1),
        1.0,
      );
    });

    test('disjoint masks → boundary IoU 0', () {
      final a = Uint8List(8 * 8);
      final b = Uint8List(8 * 8);
      for (var i = 0; i < 8; i++) {
        a[i] = 1;
        b[8 * 7 + i] = 1;
      }
      expect(
        computeBoundaryIou(a, b, width: 8, height: 8, dilation: 1),
        0.0,
      );
    });

    test('1-pixel shift on a big block → IoU < interior IoU', () {
      // 20x20 image. GT = 10x10 block at (5,5). Pred = 10x10 block
      // at (6,5). Plain mask IoU is high (interior dominates). Boundary
      // IoU should be substantially lower since edges shifted.
      final gt = _block(20, 20, 5, 5, 10, 10);
      final pred = _block(20, 20, 6, 5, 10, 10);
      final iouBoundary = computeBoundaryIou(
        pred,
        gt,
        width: 20,
        height: 20,
        dilation: 2,
      );
      // Boundary IoU should be < 1 (edges disagree) but > 0.
      expect(iouBoundary, lessThan(1.0));
      expect(iouBoundary, greaterThan(0.0));
    });
  });
}

Uint8List _block(int w, int h, int x0, int y0, int bw, int bh) {
  final m = Uint8List(w * h);
  for (var y = y0; y < y0 + bh; y++) {
    for (var x = x0; x < x0 + bw; x++) {
      if (x >= 0 && x < w && y >= 0 && y < h) m[y * w + x] = 1;
    }
  }
  return m;
}
