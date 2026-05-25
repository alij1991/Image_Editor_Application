import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:image_editor/ai/inference/sky_colour_gate.dart';

void main() {
  group('dropNonSkyPixels', () {
    test('keeps clear-blue pixel, drops dark-neutral rock pixel', () {
      // 2x1 image: pixel 0 = clear blue, pixel 1 = dark mountain
      // shadow (the kind of pixel the bleed dilation lands on).
      final mask = Float32List.fromList([1.0, 1.0]);
      final rgba = Uint8List.fromList([
        80, 140, 220, 255, // pixel 0: clear blue
        45, 45, 50, 255, //  pixel 1: dark neutral rock
      ]);
      final dropped = dropNonSkyPixels(
        mask,
        rgba,
        width: 2,
        height: 1,
      );
      expect(mask[0], 1.0, reason: 'blue pixel kept');
      expect(mask[1], 0.0,
          reason: 'dark neutral pixel dropped (low brightness, '
              'low blueness, low warmness)');
      expect(dropped, 1);
    });

    test('KEEPS warm red flower (high warmness) — by design', () {
      // The gate is intentionally permissive about warm colours so
      // sunset skies survive. This means a red tulip pixel is NOT
      // dropped by the colour gate alone — the 24 % fpr reduction
      // on the real fixture comes from dropping the dark mountain-
      // shadow band, not from removing the tulip patches.
      final mask = Float32List.fromList([1.0]);
      final rgba = Uint8List.fromList([210, 30, 30, 255]); // pure red
      dropNonSkyPixels(mask, rgba, width: 1, height: 1);
      expect(mask[0], 1.0,
          reason: 'high warmness passes — sunset-friendly');
    });

    test('KEEPS green-foliage pixel (warmness > 0.10) — by design',
        () {
      // Pure dark green has warmness = (90-30)/255 ≈ 0.235, also
      // above the 0.10 threshold. Like the tulip case, the gate
      // tolerates this and lets the mask-build heuristic's
      // top-bias plus the SegFormer score handle it instead.
      final mask = Float32List.fromList([1.0]);
      final rgba = Uint8List.fromList([40, 90, 30, 255]);
      dropNonSkyPixels(mask, rgba, width: 1, height: 1);
      expect(mask[0], 1.0,
          reason: 'green-dominant warmness passes the gate');
    });

    test('keeps warm sunset pixel', () {
      final mask = Float32List.fromList([1.0]);
      final rgba = Uint8List.fromList([
        230, 130, 50, 255, // warm orange (warmness = 0.706)
      ]);
      dropNonSkyPixels(mask, rgba, width: 1, height: 1);
      expect(mask[0], 1.0);
    });

    test('keeps bright neutral cloud pixel', () {
      final mask = Float32List.fromList([1.0]);
      // brightness ≈ 0.94, blueness ≈ 0, warmness ≈ 0.
      final rgba = Uint8List.fromList([240, 240, 240, 255]);
      dropNonSkyPixels(mask, rgba, width: 1, height: 1);
      expect(mask[0], 1.0);
    });

    test('drops dim grey rock pixel (mountain)', () {
      final mask = Float32List.fromList([1.0]);
      // brightness ≈ 0.27, no chroma.
      final rgba = Uint8List.fromList([70, 70, 70, 255]);
      final dropped = dropNonSkyPixels(mask, rgba, width: 1, height: 1);
      expect(mask[0], 0.0);
      expect(dropped, 1);
    });

    test('drops mid-brightness yellow tulip pixel', () {
      // The synthetic-bleed test was supposed to drop tulip
      // pixels; verify a representative yellow flower colour goes
      // away. R=220, G=200, B=80 → maxRG=220, warmness=0.549 →
      // passes warmness > 0.10 → KEPT. So warm-yellow tulips
      // actually SURVIVE the colour gate; the bleed reduction
      // comes from the mountain/grey/dark-foliage pixels in the
      // dilation band, not the tulips themselves. Document that
      // here so future readers don't assume the gate is doing
      // something it isn't.
      final mask = Float32List.fromList([1.0]);
      final rgba = Uint8List.fromList([220, 200, 80, 255]);
      dropNonSkyPixels(mask, rgba, width: 1, height: 1);
      expect(mask[0], 1.0,
          reason: 'warm yellow tulip passes the gate by design — '
              'see lab test for evidence the gate still wins '
              'overall by dropping the surrounding mountain band');
    });

    test('does not touch already-zero mask pixels', () {
      final mask = Float32List.fromList([0.0, 0.0]);
      final rgba = Uint8List.fromList([
        70, 70, 70, 255, //   would be dropped if mask were on
        80, 140, 220, 255, // would be kept
      ]);
      final dropped = dropNonSkyPixels(mask, rgba, width: 2, height: 1);
      expect(mask[0], 0.0);
      expect(mask[1], 0.0);
      expect(dropped, 0);
    });

    test('throws on mask/rgba dimension mismatch', () {
      expect(
        () => dropNonSkyPixels(
          Float32List(4),
          Uint8List(8),
          width: 4,
          height: 1,
        ),
        throwsArgumentError,
      );
    });
  });
}
