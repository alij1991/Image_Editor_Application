import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:image_editor/ai/inference/rgb_ops.dart';

void main() {
  group('RgbOps.brightenRgb — validation', () {
    test('rejects non-positive dimensions', () {
      expect(
        () => RgbOps.brightenRgb(
          source: Uint8List(16),
          width: 0,
          height: 2,
          factor: 1.5,
        ),
        throwsArgumentError,
      );
    });

    test('rejects length mismatch', () {
      expect(
        () => RgbOps.brightenRgb(
          source: Uint8List(8),
          width: 2,
          height: 2,
          factor: 1.5,
        ),
        throwsArgumentError,
      );
    });

    test('rejects negative factor', () {
      expect(
        () => RgbOps.brightenRgb(
          source: Uint8List(16),
          width: 2,
          height: 2,
          factor: -0.1,
        ),
        throwsArgumentError,
      );
    });
  });

  group('RgbOps.brightenRgb — values', () {
    test('factor 1.0 is identity on RGB', () {
      final src = Uint8List.fromList([
        10, 20, 30, 255,
        40, 50, 60, 200,
      ]);
      final out = RgbOps.brightenRgb(
        source: src,
        width: 2,
        height: 1,
        factor: 1.0,
      );
      expect(out, orderedEquals(src));
      expect(identical(out, src), false);
    });

    test('factor 2.0 doubles RGB and clamps', () {
      final src = Uint8List.fromList([
        50, 100, 200, 255,
      ]);
      final out = RgbOps.brightenRgb(
        source: src,
        width: 1,
        height: 1,
        factor: 2.0,
      );
      expect(out[0], 100);
      expect(out[1], 200);
      expect(out[2], 255); // clamped from 400
      expect(out[3], 255); // alpha unchanged
    });

    test('factor 0.0 zeroes RGB, alpha preserved', () {
      final src = Uint8List.fromList([200, 200, 200, 128]);
      final out = RgbOps.brightenRgb(
        source: src,
        width: 1,
        height: 1,
        factor: 0.0,
      );
      expect(out[0], 0);
      expect(out[1], 0);
      expect(out[2], 0);
      expect(out[3], 128);
    });

    test('caller input is not mutated', () {
      final src = Uint8List.fromList([50, 100, 150, 255]);
      RgbOps.brightenRgb(
        source: src,
        width: 1,
        height: 1,
        factor: 3.0,
      );
      expect(src[0], 50);
      expect(src[1], 100);
      expect(src[2], 150);
    });
  });

  group('RgbOps.whitenRgb — validation', () {
    test('rejects out-of-range desaturate', () {
      expect(
        () => RgbOps.whitenRgb(
          source: Uint8List(4),
          width: 1,
          height: 1,
          desaturate: -0.1,
          brightness: 1.0,
        ),
        throwsArgumentError,
      );
      expect(
        () => RgbOps.whitenRgb(
          source: Uint8List(4),
          width: 1,
          height: 1,
          desaturate: 1.5,
          brightness: 1.0,
        ),
        throwsArgumentError,
      );
    });

    test('rejects negative brightness', () {
      expect(
        () => RgbOps.whitenRgb(
          source: Uint8List(4),
          width: 1,
          height: 1,
          desaturate: 0.5,
          brightness: -0.1,
        ),
        throwsArgumentError,
      );
    });
  });

  group('RgbOps.whitenRgb — values', () {
    test('desaturate 0, brightness 1 is identity', () {
      final src = Uint8List.fromList([200, 100, 50, 255]);
      final out = RgbOps.whitenRgb(
        source: src,
        width: 1,
        height: 1,
        desaturate: 0.0,
        brightness: 1.0,
      );
      // Within rounding tolerance of identity.
      expect(out[0], inInclusiveRange(199, 200));
      expect(out[1], inInclusiveRange(99, 100));
      expect(out[2], inInclusiveRange(49, 50));
      expect(out[3], 255);
    });

    test('desaturate 1 collapses RGB to the luminance', () {
      // Pure red: L = 0.2126 * 255 ≈ 54.2
      final src = Uint8List.fromList([255, 0, 0, 255]);
      final out = RgbOps.whitenRgb(
        source: src,
        width: 1,
        height: 1,
        desaturate: 1.0,
        brightness: 1.0,
      );
      expect(out[0], inInclusiveRange(53, 55));
      expect(out[1], inInclusiveRange(53, 55));
      expect(out[2], inInclusiveRange(53, 55));
      expect(out[3], 255);
    });

    test('brightness scales after desaturation and clamps at 255', () {
      final src = Uint8List.fromList([128, 128, 128, 200]);
      final out = RgbOps.whitenRgb(
        source: src,
        width: 1,
        height: 1,
        desaturate: 0.5,
        brightness: 3.0,
      );
      // 128 * 3 = 384 → clamp to 255.
      expect(out[0], 255);
      expect(out[1], 255);
      expect(out[2], 255);
      expect(out[3], 200);
    });

    test('alpha is preserved regardless of ops', () {
      final src = Uint8List.fromList([0, 0, 0, 77]);
      final out = RgbOps.whitenRgb(
        source: src,
        width: 1,
        height: 1,
        desaturate: 1.0,
        brightness: 2.0,
      );
      expect(out[3], 77);
    });

    test('caller input is not mutated', () {
      final src = Uint8List.fromList([200, 100, 50, 255]);
      RgbOps.whitenRgb(
        source: src,
        width: 1,
        height: 1,
        desaturate: 1.0,
        brightness: 2.0,
      );
      expect(src[0], 200);
      expect(src[1], 100);
      expect(src[2], 50);
    });
  });
}
