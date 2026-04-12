import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:image_editor/ai/inference/sky_mask_builder.dart';

/// Build a 4x4 RGBA test image where the top two rows are a
/// "sky-like" bright-blue and the bottom two rows are a dark
/// earth-toned color. Used to validate the heuristic picks sky
/// vs. non-sky correctly.
Uint8List _skyOverGround({int w = 4, int h = 4}) {
  final out = Uint8List(w * h * 4);
  for (int y = 0; y < h; y++) {
    final isSky = y < h / 2;
    for (int x = 0; x < w; x++) {
      final idx = (y * w + x) * 4;
      if (isSky) {
        // Bright blue sky: R=120, G=170, B=230.
        out[idx] = 120;
        out[idx + 1] = 170;
        out[idx + 2] = 230;
      } else {
        // Dark brown earth: R=70, G=50, B=30.
        out[idx] = 70;
        out[idx + 1] = 50;
        out[idx + 2] = 30;
      }
      out[idx + 3] = 255;
    }
  }
  return out;
}

void main() {
  group('SkyMaskBuilder.build — validation', () {
    test('rejects non-positive dimensions', () {
      expect(
        () => SkyMaskBuilder.build(
          source: Uint8List(16),
          width: 0,
          height: 2,
        ),
        throwsArgumentError,
      );
    });

    test('rejects mismatched buffer length', () {
      expect(
        () => SkyMaskBuilder.build(
          source: Uint8List(8),
          width: 2,
          height: 2,
        ),
        throwsArgumentError,
      );
    });

    test('rejects out-of-range threshold', () {
      expect(
        () => SkyMaskBuilder.build(
          source: Uint8List(16),
          width: 2,
          height: 2,
          threshold: -0.1,
        ),
        throwsArgumentError,
      );
      expect(
        () => SkyMaskBuilder.build(
          source: Uint8List(16),
          width: 2,
          height: 2,
          threshold: 1.5,
        ),
        throwsArgumentError,
      );
    });

    test('rejects negative feather width', () {
      expect(
        () => SkyMaskBuilder.build(
          source: Uint8List(16),
          width: 2,
          height: 2,
          featherWidth: -0.01,
        ),
        throwsArgumentError,
      );
    });
  });

  group('SkyMaskBuilder.build — behavior', () {
    test('bright-blue top half scores as sky, dark bottom half does not', () {
      final src = _skyOverGround(w: 8, h: 8);
      final mask = SkyMaskBuilder.build(
        source: src,
        width: 8,
        height: 8,
      );
      expect(mask.length, 64);
      // Top-center pixel should be firmly sky.
      expect(mask[1 * 8 + 4], greaterThan(0.8));
      // Bottom-center pixel should be firmly ground.
      expect(mask[7 * 8 + 4], 0);
    });

    test('all-black image → mask is all zero', () {
      final src = Uint8List(4 * 4 * 4);
      // alpha = 255, RGB = 0
      for (int i = 3; i < src.length; i += 4) {
        src[i] = 255;
      }
      final mask = SkyMaskBuilder.build(
        source: src,
        width: 4,
        height: 4,
      );
      for (final v in mask) {
        expect(v, 0,
            reason: 'no brightness + no blueness + low score');
      }
    });

    test('all-white image → upper half still scores high via top bias', () {
      final src = Uint8List(4 * 4 * 4);
      for (int i = 0; i < src.length; i += 4) {
        src[i] = 255;
        src[i + 1] = 255;
        src[i + 2] = 255;
        src[i + 3] = 255;
      }
      final mask = SkyMaskBuilder.build(
        source: src,
        width: 4,
        height: 4,
      );
      // Top row gets bright + top bias — should cross threshold.
      expect(mask[0], greaterThan(0.5));
    });

    test('hard threshold (feather=0) produces binary mask', () {
      final src = _skyOverGround();
      final mask = SkyMaskBuilder.build(
        source: src,
        width: 4,
        height: 4,
        featherWidth: 0,
      );
      for (final v in mask) {
        expect(v == 0.0 || v == 1.0, isTrue,
            reason: 'every value must be 0 or 1 in hard-threshold mode');
      }
    });

    test('feather > 0 yields at least one intermediate value', () {
      // A 2-pixel-tall image with a slightly-above-threshold top
      // pixel — the feather ramp ensures the value is not a hard 1.
      final src = Uint8List.fromList([
        100, 120, 140, 255,
        30, 30, 30, 255,
      ]);
      final mask = SkyMaskBuilder.build(
        source: src,
        width: 1,
        height: 2,
        threshold: 0.5,
        featherWidth: 0.6,
      );
      // Top pixel should land inside the feather band.
      expect(mask[0], greaterThan(0));
      expect(mask[0], lessThan(1));
    });

    test('output is deterministic', () {
      final src = _skyOverGround();
      final a = SkyMaskBuilder.build(
        source: src,
        width: 4,
        height: 4,
      );
      final b = SkyMaskBuilder.build(
        source: src,
        width: 4,
        height: 4,
      );
      expect(a, orderedEquals(b));
    });
  });
}
