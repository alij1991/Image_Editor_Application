import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:image_editor/ai/inference/rgb_ops.dart';

/// Phase XV.2: pins the LAB a*/b* masked shift's invariants —
/// preservation of unmasked pixels, preservation of alpha, and a
/// qualitative check that the shift pushes mid-grey toward the
/// target colour while leaving luminance roughly intact.
void main() {
  group('RgbOps.shiftLabAbForMaskedPixels', () {
    test('unmasked pixels are byte-identical to source', () {
      final src = Uint8List.fromList([
        // row 1
        100, 150, 200, 255,
        50, 60, 70, 255,
        // row 2
        10, 20, 30, 255,
        240, 250, 255, 255,
      ]);
      final mask = Float32List.fromList([0.0, 0.0, 0.0, 0.0]);
      final out = RgbOps.shiftLabAbForMaskedPixels(
        source: src,
        width: 2,
        height: 2,
        mask: mask,
        targetR: 255,
        targetG: 0,
        targetB: 0,
      );
      expect(out, equals(src));
    });

    test('alpha channel is copied through even when mask=1', () {
      final src = Uint8List.fromList([
        128, 128, 128, 200, // grey @ A=200
      ]);
      final mask = Float32List.fromList([1.0]);
      final out = RgbOps.shiftLabAbForMaskedPixels(
        source: src,
        width: 1,
        height: 1,
        mask: mask,
        targetR: 255,
        targetG: 0,
        targetB: 0,
      );
      expect(out[3], 200);
    });

    test('masked grey pixel shifts toward red when target is red', () {
      // Mid-grey source (128, 128, 128). After the a*/b* shift toward
      // red, the red channel should INCREASE and the green/blue
      // channels should DECREASE — the L* is preserved so the
      // result stays approximately mid-luminance.
      final src = Uint8List.fromList([128, 128, 128, 255]);
      final mask = Float32List.fromList([1.0]);
      final out = RgbOps.shiftLabAbForMaskedPixels(
        source: src,
        width: 1,
        height: 1,
        mask: mask,
        targetR: 200,
        targetG: 30,
        targetB: 30,
      );
      expect(out[0], greaterThan(128), reason: 'red should go up');
      expect(out[1], lessThan(128), reason: 'green should go down');
      expect(out[2], lessThan(128), reason: 'blue should go down');
    });

    test('strength=0 is a no-op (source pixels preserved exactly)', () {
      final src = Uint8List.fromList([200, 50, 80, 255]);
      final mask = Float32List.fromList([1.0]);
      final out = RgbOps.shiftLabAbForMaskedPixels(
        source: src,
        width: 1,
        height: 1,
        mask: mask,
        targetR: 0,
        targetG: 0,
        targetB: 255,
        strength: 0.0,
      );
      expect(out, equals(src));
    });

    test('throws on mask length mismatch', () {
      final src = Uint8List(16); // 2x2 RGBA
      final mask = Float32List(3); // wrong length
      expect(
        () => RgbOps.shiftLabAbForMaskedPixels(
          source: src,
          width: 2,
          height: 2,
          mask: mask,
          targetR: 0,
          targetG: 0,
          targetB: 0,
        ),
        throwsArgumentError,
      );
    });

    test('clamps strength to [0, 1]', () {
      // Strength > 1 is clamped to 1 — check by running with 5.0 and
      // comparing to the 1.0 reference. Both should be identical.
      final src = Uint8List.fromList([100, 100, 100, 255]);
      final mask = Float32List.fromList([1.0]);
      final ref = RgbOps.shiftLabAbForMaskedPixels(
        source: src,
        width: 1,
        height: 1,
        mask: mask,
        targetR: 200,
        targetG: 50,
        targetB: 50,
        strength: 1.0,
      );
      final over = RgbOps.shiftLabAbForMaskedPixels(
        source: src,
        width: 1,
        height: 1,
        mask: mask,
        targetR: 200,
        targetG: 50,
        targetB: 50,
        strength: 5.0,
      );
      expect(over, equals(ref));
    });
  });
}
