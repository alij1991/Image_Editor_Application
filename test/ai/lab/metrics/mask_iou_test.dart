import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:image_editor/ai/lab/metrics/mask_iou.dart';

void main() {
  group('binariseFloatMask', () {
    test('threshold at 0.5 by default', () {
      final m = Float32List.fromList([0.0, 0.4, 0.5, 0.9, 1.0]);
      expect(binariseFloatMask(m), [0, 0, 1, 1, 1]);
    });

    test('custom threshold', () {
      final m = Float32List.fromList([0.1, 0.3, 0.6]);
      expect(binariseFloatMask(m, threshold: 0.4), [0, 0, 1]);
    });
  });

  group('binariseByteMask', () {
    test('single-channel binarise at 128', () {
      final m = Uint8List.fromList([0, 127, 128, 200, 255]);
      expect(binariseByteMask(m), [0, 0, 1, 1, 1]);
    });

    test('RGBA: uses alpha channel only', () {
      final m = Uint8List.fromList([
        255, 255, 255, 0, // alpha=0 → 0
        0, 0, 0, 200, //   alpha=200 → 1
        100, 100, 100, 127, // alpha=127 → 0
        50, 50, 50, 255, //   alpha=255 → 1
      ]);
      expect(binariseByteMask(m, stride: 4), [0, 1, 0, 1]);
    });
  });

  group('computeMaskIou', () {
    test('identical masks → IoU 1.0', () {
      final a = Uint8List.fromList([1, 1, 0, 0, 1, 1, 0, 0]);
      expect(computeMaskIou(a, a), 1.0);
    });

    test('disjoint masks → IoU 0', () {
      final a = Uint8List.fromList([1, 1, 0, 0]);
      final b = Uint8List.fromList([0, 0, 1, 1]);
      expect(computeMaskIou(a, b), 0.0);
    });

    test('half overlap → 1/3', () {
      // pred = [1,1,0,0,0], gt = [0,1,1,0,0]
      // intersection = 1 (idx 1), union = 3 (idx 0,1,2) → 1/3
      final a = Uint8List.fromList([1, 1, 0, 0, 0]);
      final b = Uint8List.fromList([0, 1, 1, 0, 0]);
      expect(computeMaskIou(a, b), closeTo(1 / 3, 1e-9));
    });

    test('both empty → IoU 1 (vacuous agreement)', () {
      final a = Uint8List(16);
      final b = Uint8List(16);
      expect(computeMaskIou(a, b), 1.0);
    });

    test('mismatched sizes throws', () {
      expect(
        () => computeMaskIou(Uint8List(4), Uint8List(8)),
        throwsArgumentError,
      );
    });
  });

  group('computeMaskCoverage', () {
    test('counts cells set to 1', () {
      final m = Uint8List.fromList([1, 0, 1, 0, 1, 0, 1, 0]);
      expect(computeMaskCoverage(m), 0.5);
    });

    test('empty mask → 0', () {
      expect(computeMaskCoverage(Uint8List(8)), 0.0);
    });
  });

  group('computeFalsePositiveRate', () {
    test('false positives outside gt counted', () {
      // pred sets 3 pixels, gt sets 2 — overlap = 1, FP = 2.
      final pred = Uint8List.fromList([1, 1, 1, 0, 0, 0]);
      final gt = Uint8List.fromList([1, 0, 0, 1, 0, 0]);
      // FP pixels: idx 1, 2  → 2/6.
      expect(computeFalsePositiveRate(pred, gt), closeTo(2 / 6, 1e-9));
    });

    test('all positives inside gt → FP rate 0', () {
      final pred = Uint8List.fromList([1, 1, 0, 0]);
      final gt = Uint8List.fromList([1, 1, 0, 0]);
      expect(computeFalsePositiveRate(pred, gt), 0.0);
    });
  });
}
