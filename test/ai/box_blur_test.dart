import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:image_editor/ai/inference/box_blur.dart';

void main() {
  group('BoxBlur.blurRgba — validation', () {
    test('rejects non-positive dimensions', () {
      expect(
        () => BoxBlur.blurRgba(
          source: Uint8List(16),
          width: 0,
          height: 2,
          radius: 1,
        ),
        throwsArgumentError,
      );
    });

    test('rejects mismatched buffer length', () {
      expect(
        () => BoxBlur.blurRgba(
          source: Uint8List(8),
          width: 2,
          height: 2,
          radius: 1,
        ),
        throwsArgumentError,
      );
    });

    test('rejects negative radius', () {
      expect(
        () => BoxBlur.blurRgba(
          source: Uint8List(16),
          width: 2,
          height: 2,
          radius: -1,
        ),
        throwsArgumentError,
      );
    });
  });

  group('BoxBlur.blurRgba — values', () {
    test('radius 0 returns an exact copy', () {
      final src = Uint8List.fromList([
        10, 20, 30, 255,
        40, 50, 60, 200,
        70, 80, 90, 150,
        100, 110, 120, 100,
      ]);
      final out = BoxBlur.blurRgba(
        source: src,
        width: 2,
        height: 2,
        radius: 0,
      );
      expect(out, orderedEquals(src));
      // Confirm it's a copy, not the same buffer.
      expect(identical(out, src), false);
    });

    test('alpha channel is never blurred', () {
      // Two pixels: full alpha + zero alpha. After blur with radius
      // 1, alpha must stay [255, 0] — only RGB averages.
      final src = Uint8List.fromList([
        100, 100, 100, 255,
        200, 200, 200, 0,
      ]);
      final out = BoxBlur.blurRgba(
        source: src,
        width: 2,
        height: 1,
        radius: 1,
      );
      expect(out[3], 255);
      expect(out[7], 0);
      // RGB should average toward the middle.
      expect(out[0], inInclusiveRange(140, 160));
      expect(out[4], inInclusiveRange(140, 160));
    });

    test('uniform input → uniform output', () {
      final src = Uint8List(64);
      for (int i = 0; i < 16; i++) {
        src[i * 4] = 128;
        src[i * 4 + 1] = 64;
        src[i * 4 + 2] = 32;
        src[i * 4 + 3] = 255;
      }
      final out = BoxBlur.blurRgba(
        source: src,
        width: 4,
        height: 4,
        radius: 2,
      );
      // Every pixel should still be (128, 64, 32, 255) — averaging
      // a uniform field is identity.
      for (int i = 0; i < 16; i++) {
        expect(out[i * 4], 128);
        expect(out[i * 4 + 1], 64);
        expect(out[i * 4 + 2], 32);
        expect(out[i * 4 + 3], 255);
      }
    });

    test('blur smooths a hard edge', () {
      // 4x1 image with a sharp black/white edge in the middle.
      final src = Uint8List.fromList([
        0, 0, 0, 255,
        0, 0, 0, 255,
        255, 255, 255, 255,
        255, 255, 255, 255,
      ]);
      final out = BoxBlur.blurRgba(
        source: src,
        width: 4,
        height: 1,
        radius: 1,
      );
      // After a 3-pixel box blur:
      // pixel 0: avg(0, 0)            = 0
      // pixel 1: avg(0, 0, 255)       = 85
      // pixel 2: avg(0, 255, 255)     = 170
      // pixel 3: avg(255, 255)        = 255
      expect(out[0], 0);
      expect(out[4], inInclusiveRange(80, 90));
      expect(out[8], inInclusiveRange(165, 175));
      expect(out[12], 255);
    });
  });
}
