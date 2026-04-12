import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';

import 'package:image_editor/ai/inference/landmark_mask_builder.dart';

void main() {
  group('LandmarkMaskBuilder.build — validation', () {
    test('rejects non-positive dimensions', () {
      expect(
        () => LandmarkMaskBuilder.build(
          spots: const [],
          width: 0,
          height: 10,
        ),
        throwsArgumentError,
      );
      expect(
        () => LandmarkMaskBuilder.build(
          spots: const [],
          width: 10,
          height: -1,
        ),
        throwsArgumentError,
      );
    });

    test('rejects out-of-range feather', () {
      expect(
        () => LandmarkMaskBuilder.build(
          spots: const [],
          width: 10,
          height: 10,
          feather: -0.1,
        ),
        throwsArgumentError,
      );
      expect(
        () => LandmarkMaskBuilder.build(
          spots: const [],
          width: 10,
          height: 10,
          feather: 1.5,
        ),
        throwsArgumentError,
      );
    });
  });

  group('LandmarkMaskBuilder.build — behavior', () {
    test('empty spots → all-zero mask of correct length', () {
      final mask = LandmarkMaskBuilder.build(
        spots: const [],
        width: 8,
        height: 4,
      );
      expect(mask.length, 32);
      expect(mask.every((v) => v == 0), true);
    });

    test('single spot draws a circle with ≈1.0 at center', () {
      final mask = LandmarkMaskBuilder.build(
        spots: const [
          LandmarkSpot(center: ui.Offset(50, 50), radius: 10),
        ],
        width: 100,
        height: 100,
      );
      // Center pixel should be fully opaque.
      expect(mask[50 * 100 + 50], greaterThan(0.99));
      // A pixel far outside should be 0.
      expect(mask[5 * 100 + 5], 0);
    });

    test('zero-radius spot draws nothing', () {
      final mask = LandmarkMaskBuilder.build(
        spots: const [
          LandmarkSpot(center: ui.Offset(50, 50), radius: 0),
        ],
        width: 100,
        height: 100,
      );
      expect(mask.every((v) => v == 0), true);
    });

    test('feather 0 gives a hard edge', () {
      final mask = LandmarkMaskBuilder.build(
        spots: const [
          LandmarkSpot(center: ui.Offset(50, 50), radius: 5),
        ],
        width: 100,
        height: 100,
        feather: 0.0,
      );
      // Pixel at the center must be 1.0.
      expect(mask[50 * 100 + 50], 1.0);
      // Pixel just outside the radius (distance 10) must be 0.
      expect(mask[50 * 100 + 60], 0.0);
    });

    test('feather 1 gives a fully soft falloff', () {
      final mask = LandmarkMaskBuilder.build(
        spots: const [
          LandmarkSpot(center: ui.Offset(50, 50), radius: 10),
        ],
        width: 100,
        height: 100,
        feather: 1.0,
      );
      // Center still hits 1.
      expect(mask[50 * 100 + 50], closeTo(1.0, 1e-6));
      // Halfway point should be somewhere in the middle.
      expect(mask[50 * 100 + 55], inInclusiveRange(0.1, 0.9));
    });

    test('overlapping spots use max-combine (not additive)', () {
      final mask = LandmarkMaskBuilder.build(
        spots: const [
          LandmarkSpot(center: ui.Offset(50, 50), radius: 10),
          LandmarkSpot(center: ui.Offset(52, 50), radius: 10),
        ],
        width: 100,
        height: 100,
      );
      double globalMax = 0;
      for (final v in mask) {
        if (v > globalMax) globalMax = v;
      }
      expect(globalMax, lessThanOrEqualTo(1.0));
      expect(globalMax, greaterThan(0.99));
    });

    test('spots outside image bounds clip cleanly', () {
      final mask = LandmarkMaskBuilder.build(
        spots: const [
          LandmarkSpot(center: ui.Offset(-5, -5), radius: 10),
        ],
        width: 50,
        height: 50,
      );
      // Top-left corner should still receive some alpha because
      // the circle clips into the image.
      expect(mask[0], greaterThan(0));
      // Far corner should not be touched.
      expect(mask[49 * 50 + 49], 0);
    });

    test('spots fully outside image produce zero mask', () {
      final mask = LandmarkMaskBuilder.build(
        spots: const [
          LandmarkSpot(center: ui.Offset(-100, -100), radius: 5),
        ],
        width: 50,
        height: 50,
      );
      expect(mask.every((v) => v == 0), true);
    });
  });
}
