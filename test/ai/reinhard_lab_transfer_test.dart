import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:image_editor/ai/inference/rgb_ops.dart';

/// Phase XV.3: unit tests for [RgbOps.reinhardLabTransfer]. The
/// important invariants:
///   - Unmasked pixels are byte-identical to source (alpha included).
///   - strength=0 is a no-op across all masked pixels.
///   - Applying the transfer shifts the masked pixels toward the
///     target's colour centroid.
///   - Throws on length mismatches.
void main() {
  group('RgbOps.reinhardLabTransfer', () {
    test('unmasked pixels are preserved exactly (mask all zero)', () {
      // 2×2 source + target, mask all zero → identity.
      final src = Uint8List.fromList([
        10, 20, 30, 255,
        40, 50, 60, 255,
        70, 80, 90, 255,
        100, 110, 120, 255,
      ]);
      final tgt = Uint8List.fromList([
        200, 200, 200, 255,
        200, 200, 200, 255,
        200, 200, 200, 255,
        200, 200, 200, 255,
      ]);
      final mask = Float32List(4);
      final out = RgbOps.reinhardLabTransfer(
        source: src,
        width: 2,
        height: 2,
        target: tgt,
        mask: mask,
      );
      expect(out, equals(src));
    });

    test('strength=0 keeps every masked pixel unchanged', () {
      final src = Uint8List.fromList([100, 120, 140, 255]);
      final tgt = Uint8List.fromList([50, 50, 50, 255]);
      final mask = Float32List.fromList([1.0]);
      final out = RgbOps.reinhardLabTransfer(
        source: src,
        width: 1,
        height: 1,
        target: tgt,
        mask: mask,
        strength: 0.0,
      );
      expect(out, equals(src));
    });

    test('alpha channel is preserved even at strength=1', () {
      // Build a 2x2 image with varied src pixels + varied tgt so
      // statistics are non-degenerate (stddev > 0).
      final src = Uint8List.fromList([
        40, 60, 200, 128,
        80, 120, 200, 200,
        60, 100, 180, 64,
        50, 90, 220, 32,
      ]);
      final tgt = Uint8List.fromList([
        200, 80, 40, 255,
        220, 70, 30, 255,
        210, 90, 50, 255,
        190, 85, 45, 255,
      ]);
      final mask = Float32List.fromList([1.0, 1.0, 1.0, 1.0]);
      final out = RgbOps.reinhardLabTransfer(
        source: src,
        width: 2,
        height: 2,
        target: tgt,
        mask: mask,
      );
      expect(out[3], 128);
      expect(out[7], 200);
      expect(out[11], 64);
      expect(out[15], 32);
    });

    test('masked blue source shifts toward warm target', () {
      // Blue source → orange target. The mean shift should push
      // every source pixel's red channel up and blue channel down.
      // Use a small non-degenerate set so stddev is >0.
      final src = Uint8List.fromList([
        30, 60, 200, 255,
        40, 80, 210, 255,
        20, 70, 190, 255,
        35, 65, 205, 255,
      ]);
      final tgt = Uint8List.fromList([
        220, 100, 30, 255,
        230, 110, 40, 255,
        210, 90, 20, 255,
        225, 95, 35, 255,
      ]);
      final mask = Float32List.fromList([1.0, 1.0, 1.0, 1.0]);
      final out = RgbOps.reinhardLabTransfer(
        source: src,
        width: 2,
        height: 2,
        target: tgt,
        mask: mask,
      );
      // Every output pixel should have red > blue after the shift.
      for (int i = 0; i < out.length; i += 4) {
        expect(out[i], greaterThan(out[i + 2]),
            reason: 'expected red > blue after warm transfer at $i');
      }
    });

    test('throws when source length does not match width×height', () {
      final src = Uint8List(12); // 3 px worth of RGBA; expects 16
      final tgt = Uint8List(16);
      final mask = Float32List(4);
      expect(
        () => RgbOps.reinhardLabTransfer(
          source: src,
          width: 2,
          height: 2,
          target: tgt,
          mask: mask,
        ),
        throwsArgumentError,
      );
    });

    test('no-op when no pixels are masked (zero-count guard)', () {
      // Mask below threshold → no source stats computed → pass-through.
      final src = Uint8List.fromList([100, 110, 120, 255]);
      final tgt = Uint8List.fromList([200, 200, 200, 255]);
      final mask = Float32List.fromList([0.05]);
      final out = RgbOps.reinhardLabTransfer(
        source: src,
        width: 1,
        height: 1,
        target: tgt,
        mask: mask,
        maskThreshold: 0.1,
      );
      expect(out, equals(src));
    });
  });
}
