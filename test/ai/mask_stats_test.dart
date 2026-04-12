import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:image_editor/ai/inference/mask_stats.dart';

void main() {
  group('MaskStats.compute', () {
    test('empty mask → all zeros', () {
      final stats = MaskStats.compute(Float32List(0));
      expect(stats.min, 0);
      expect(stats.max, 0);
      expect(stats.mean, 0);
      expect(stats.nonZero, 0);
      expect(stats.length, 0);
      expect(stats.isEffectivelyEmpty, true);
      expect(stats.isEffectivelyFull, false);
    });

    test('all-zero mask → empty flag set', () {
      final mask = Float32List.fromList(const [0, 0, 0, 0]);
      final stats = MaskStats.compute(mask);
      expect(stats.min, 0);
      expect(stats.max, 0);
      expect(stats.mean, 0);
      expect(stats.nonZero, 0);
      expect(stats.length, 4);
      expect(stats.isEffectivelyEmpty, true);
      expect(stats.isEffectivelyFull, false);
    });

    test('all-one mask → full flag set', () {
      final mask = Float32List.fromList(const [1, 1, 1, 1]);
      final stats = MaskStats.compute(mask);
      expect(stats.min, 1);
      expect(stats.max, 1);
      expect(stats.mean, 1);
      expect(stats.nonZero, 4);
      expect(stats.isEffectivelyEmpty, false);
      expect(stats.isEffectivelyFull, true);
    });

    test('mixed values → neither empty nor full', () {
      final mask = Float32List.fromList(const [0.1, 0.5, 0.9, 0.0]);
      final stats = MaskStats.compute(mask);
      expect(stats.min, closeTo(0, 1e-6));
      expect(stats.max, closeTo(0.9, 1e-6));
      expect(stats.mean, closeTo((0.1 + 0.5 + 0.9 + 0.0) / 4, 1e-6));
      expect(stats.nonZero, 3, reason: '0.0 is below 0.01 threshold');
      expect(stats.isEffectivelyEmpty, false);
      expect(stats.isEffectivelyFull, false);
    });

    test('subthreshold noise does not count as nonzero', () {
      final mask = Float32List.fromList(const [0.001, 0.005, 0.009, 0.011]);
      final stats = MaskStats.compute(mask);
      expect(stats.nonZero, 1,
          reason: 'only 0.011 exceeds the 0.01 floor');
      // max is just barely above threshold → still flagged "empty"
      // because max < 0.01 is the check (0.011 > 0.01).
      expect(stats.isEffectivelyEmpty, false);
    });

    test('boundary: max slightly above threshold is not empty', () {
      // Use 0.02 to avoid float32 precision roundoff around 0.01.
      final mask = Float32List.fromList(const [0.02, 0.009, 0.008]);
      final stats = MaskStats.compute(mask);
      expect(stats.isEffectivelyEmpty, false,
          reason: 'max 0.02 is clearly above 0.01 threshold');
    });

    test('boundary: max well below threshold is empty', () {
      final mask = Float32List.fromList(const [0.001, 0.002, 0.003]);
      final stats = MaskStats.compute(mask);
      expect(stats.isEffectivelyEmpty, true);
    });

    test('large mask computes mean correctly', () {
      final mask = Float32List(1024);
      for (int i = 0; i < mask.length; i++) {
        mask[i] = (i / (mask.length - 1)).toDouble();
      }
      final stats = MaskStats.compute(mask);
      expect(stats.min, closeTo(0, 1e-6));
      expect(stats.max, closeTo(1.0, 1e-6));
      expect(stats.mean, closeTo(0.5, 1e-3));
      // Roughly half the values cross the 0.01 threshold.
      expect(stats.nonZero, greaterThan(990));
      expect(stats.length, 1024);
    });

    test('isEffectivelyFull requires min > 0.99', () {
      final almost = Float32List.fromList(const [0.995, 0.999, 1.0]);
      expect(MaskStats.compute(almost).isEffectivelyFull, true);

      // Float32 roundtrip: 0.98 is clearly below the 0.99 threshold
      // even after precision loss, so this branch is deterministic.
      final notQuite = Float32List.fromList(const [0.98, 1.0, 1.0]);
      expect(MaskStats.compute(notQuite).isEffectivelyFull, false,
          reason: 'min 0.98 is below the 0.99 threshold');
    });
  });

  group('MaskStats.toLogMap', () {
    test('renders compact string values at 3-decimal precision', () {
      final stats = MaskStats.compute(
        Float32List.fromList(const [0.1, 0.5, 0.9, 0.0]),
      );
      final m = stats.toLogMap();
      expect(m['min'], '0.000');
      expect(m['max'], '0.900');
      expect(m['nonZero'], 3);
      expect(m['length'], 4);
      // mean ≈ 0.375 → "0.375"
      expect(m['mean'], '0.375');
    });
  });
}
