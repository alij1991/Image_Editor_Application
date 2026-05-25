import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:image_editor/ai/lab/metrics/matting_metrics.dart';

void main() {
  group('unknownRegionFromTrimap', () {
    test('classifies fg/bg/unknown bytes correctly', () {
      final t = Uint8List.fromList([0, 128, 255, 110, 150, 200, 30]);
      final out = unknownRegionFromTrimap(t);
      // 0 → bg (0), 128 → unknown (1), 255 → fg (0),
      // 110/150 → unknown (within ±32 of 128) → 1,
      // 200/30 → fg/bg → 0.
      expect(out, [0, 1, 0, 1, 1, 0, 0]);
    });

    test('custom tolerance widens band', () {
      // Band: 78..178 with tolerance=50. 90/100/156 are inside, 200
      // is outside.
      final t = Uint8List.fromList([90, 100, 156, 200]);
      final out = unknownRegionFromTrimap(t, tolerance: 50);
      expect(out, [1, 1, 1, 0]);
    });
  });

  group('computeSad', () {
    test('identical alphas → SAD 0', () {
      final a = Float32List.fromList([0.0, 0.5, 1.0]);
      expect(computeSad(a, a), 0.0);
    });

    test('mean absolute difference matches manual calc', () {
      final pred = Float32List.fromList([0.0, 0.5, 1.0]);
      final gt = Float32List.fromList([0.0, 0.3, 0.6]);
      // |0|+|0.2|+|0.4| = 0.6, /3 = 0.2. Tolerance loose enough for
      // Float32 round-off accumulated across the sum.
      expect(computeSad(pred, gt), closeTo(0.2, 1e-6));
    });

    test('unknown region restricts the sum', () {
      final pred = Float32List.fromList([0.9, 0.5, 0.1, 0.5]);
      final gt = Float32List.fromList([1.0, 0.6, 0.0, 0.6]);
      // Only consider indices 1 and 3 (set in unknown).
      final unk = Uint8List.fromList([0, 1, 0, 1]);
      // |0.1| + |0.1| = 0.2, /2 = 0.1.
      expect(computeSad(pred, gt, unknownRegion: unk), closeTo(0.1, 1e-6));
    });

    test('empty inputs → SAD 0', () {
      expect(
        computeSad(Float32List(0), Float32List(0)),
        0.0,
      );
    });

    test('size mismatch throws', () {
      expect(
        () => computeSad(Float32List(2), Float32List(3)),
        throwsArgumentError,
      );
    });
  });

  group('computeGradientError', () {
    test('identical alpha → gradient error 0', () {
      final a = Float32List(5 * 5);
      // Diagonal step pattern.
      for (var y = 0; y < 5; y++) {
        for (var x = 0; x < 5; x++) {
          a[y * 5 + x] = (x + y) >= 5 ? 1.0 : 0.0;
        }
      }
      expect(
        computeGradientError(a, a, width: 5, height: 5),
        closeTo(0, 1e-9),
      );
    });

    test('sharp vs flat → gradient error > 0', () {
      final sharp = Float32List(5 * 5);
      final flat = Float32List(5 * 5);
      for (var y = 0; y < 5; y++) {
        for (var x = 0; x < 5; x++) {
          sharp[y * 5 + x] = x < 2 ? 0.0 : 1.0;
          flat[y * 5 + x] = 0.5;
        }
      }
      final err = computeGradientError(sharp, flat, width: 5, height: 5);
      expect(err, greaterThan(0));
    });

    test('returns 0 for tiny images', () {
      final tiny = Float32List(4);
      expect(
        computeGradientError(tiny, tiny, width: 2, height: 2),
        0,
      );
    });
  });
}
