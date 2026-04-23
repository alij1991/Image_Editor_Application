import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:image_editor/ai/services/compose_on_bg/compose_edge_ops.dart';

/// Phase XVI.2: unit coverage for the edge-quality helpers that turn
/// a raw matte into a composite-ready subject. Each helper is pure
/// Dart so the full contract is testable without a Flutter binding.
void main() {
  group('ComposeEdgeOps.zeroRgbWhereTransparent', () {
    test('zeroes RGB on fully-transparent pixels', () {
      final src = Uint8List.fromList([
        // fully transparent — should zero
        200, 100, 50, 0,
        // fully opaque — unchanged
        200, 100, 50, 255,
      ]);
      final out = ComposeEdgeOps.zeroRgbWhereTransparent(
        rgba: src,
        width: 2,
        height: 1,
      );
      expect(out[0], 0);
      expect(out[1], 0);
      expect(out[2], 0);
      expect(out[3], 0);
      expect(out[4], 200);
      expect(out[5], 100);
      expect(out[6], 50);
      expect(out[7], 255);
    });

    test('alpha channel itself is preserved verbatim', () {
      final src = Uint8List.fromList([
        100, 100, 100, 0,
        100, 100, 100, 128,
      ]);
      final out = ComposeEdgeOps.zeroRgbWhereTransparent(
        rgba: src,
        width: 2,
        height: 1,
      );
      expect(out[3], 0);
      expect(out[7], 128);
    });

    test('partial-alpha pixels above threshold preserved', () {
      // Default threshold=1 → pixels at alpha=1 or higher keep RGB.
      final src = Uint8List.fromList([150, 150, 150, 5]);
      final out = ComposeEdgeOps.zeroRgbWhereTransparent(
        rgba: src,
        width: 1,
        height: 1,
      );
      expect(out[0], 150);
      expect(out[1], 150);
      expect(out[2], 150);
    });

    test('threshold override zeroes pixels up to threshold-1', () {
      final src = Uint8List.fromList([150, 150, 150, 5]);
      final out = ComposeEdgeOps.zeroRgbWhereTransparent(
        rgba: src,
        width: 1,
        height: 1,
        threshold: 10,
      );
      expect(out[0], 0);
      expect(out[1], 0);
      expect(out[2], 0);
      expect(out[3], 5); // alpha unchanged
    });
  });

  group('XVI.7 regression: low-α bright pixels get wiped + interior-filled',
      () {
    test('α=2 with rgb=(255,255,255) is killed by aggressive zero + decontam',
        () {
      // Exact halo pattern from the 2026-04-22 device log:
      // a partial-alpha pixel at α=2 carrying rgb=(255,255,255)
      // from RVM's foreground estimate, sitting next to a clean
      // interior.
      final src = Uint8List.fromList([
        // Interior cluster with a consistent dark-gray colour.
        80, 80, 100, 255,
        80, 80, 100, 255,
        80, 80, 100, 255,
        80, 80, 100, 255,
        // Halo pixels — very low alpha but carrying bright fgr.
        255, 255, 255, 2,
        255, 255, 255, 5,
        // More interior so the decontamination sample has a
        // target to pull toward.
        80, 80, 100, 255,
        80, 80, 100, 255,
      ]);
      var buf = ComposeEdgeOps.zeroRgbWhereTransparent(
        rgba: src,
        width: 8,
        height: 1,
        threshold: 240,
      );
      buf = ComposeEdgeOps.decontaminateEdges(
        rgba: buf,
        width: 8,
        height: 1,
        lo: 0.005,
        radius: 8,
      );
      // The α=2 pixel at index 4 (bytes 16..19): RGB should now
      // be near the interior gray-blue (80, 80, 100), NOT white.
      expect(buf[16], lessThan(140),
          reason: 'halo red should be pulled toward interior, was $buf[16]');
      expect(buf[17], lessThan(140),
          reason: 'halo green pulled toward interior');
      expect(buf[18], lessThan(140),
          reason: 'halo blue pulled toward interior');
      expect(buf[19], 2, reason: 'alpha preserved');
    });

    test('α=255 interior unaffected by threshold=240 wipe', () {
      // Opaque interior pixels must survive the aggressive wipe.
      final src = Uint8List.fromList([
        150, 100, 80, 255,
        150, 100, 80, 255,
      ]);
      final out = ComposeEdgeOps.zeroRgbWhereTransparent(
        rgba: src,
        width: 2,
        height: 1,
        threshold: 240,
      );
      expect(out, equals(src),
          reason: 'threshold=240 should leave α=255 pixels alone');
    });
  });

  group('XVI.4 regression: feather after zero-out does not leak RGB', () {
    test('partial-alpha ramp pixels get decontaminated to interior', () {
      // Worst-case halo setup: 5×1 strip with a solid-red subject
      // at x=0..2 (alpha=255, RGB=200/0/0) and bright-white "old bg"
      // contaminated pixels at x=3..4 (alpha=0, RGB=255/255/255).
      // The XVI.2 feather-only path bumped x=3..4's alpha up,
      // resurrecting the white into the composite. The XVI.4 path
      // zeroes x=3..4 RGB first so any alpha bump composites as
      // dark-partial (blends into new bg), then decontamination
      // repaints them from the interior red.
      final src = Uint8List.fromList([
        200, 0, 0, 255,  // subject interior
        200, 0, 0, 255,
        200, 0, 0, 255,
        255, 255, 255, 0, // contaminated bg (white)
        255, 255, 255, 0,
      ]);
      var buf = ComposeEdgeOps.zeroRgbWhereTransparent(
        rgba: src,
        width: 5,
        height: 1,
      );
      buf = ComposeEdgeOps.featherAlpha(
        rgba: buf,
        width: 5,
        height: 1,
        passes: 1,
      );
      buf = ComposeEdgeOps.decontaminateEdges(
        rgba: buf,
        width: 5,
        height: 1,
        radius: 2,
      );
      // Pixel at x=3 should have been bumped to partial alpha AND
      // had its RGB repainted from the red interior — NOT the
      // white contamination.
      final x3R = buf[12];
      final x3G = buf[13];
      final x3B = buf[14];
      expect(x3R, greaterThan(100),
          reason: 'expected red bleed from interior');
      expect(x3G, lessThan(60),
          reason: 'white contamination should be gone');
      expect(x3B, lessThan(60),
          reason: 'white contamination should be gone');
    });
  });

  group('ComposeEdgeOps.erodeAlpha', () {
    test('empty/opaque flat image unchanged', () {
      // 3×3 all-opaque — nothing to erode.
      final src = Uint8List(3 * 3 * 4);
      for (int i = 0; i < src.length; i += 4) {
        src[i] = 200;
        src[i + 1] = 100;
        src[i + 2] = 50;
        src[i + 3] = 255;
      }
      final out = ComposeEdgeOps.erodeAlpha(
        rgba: src,
        width: 3,
        height: 3,
      );
      for (int i = 3; i < out.length; i += 4) {
        expect(out[i], 255);
      }
    });

    test('outer rim alpha shrinks inward by one pixel per pass', () {
      // 5×5, centre pixel is fully opaque, everything else zero.
      // After one erosion, the centre's alpha becomes 0 (smallest
      // of its 3×3 neighbourhood which is all zero).
      final src = Uint8List(5 * 5 * 4);
      const centreIdx = (2 * 5 + 2) * 4;
      src[centreIdx + 3] = 255;
      final out = ComposeEdgeOps.erodeAlpha(
        rgba: src,
        width: 5,
        height: 5,
      );
      expect(out[centreIdx + 3], 0);
    });

    test('RGB channels untouched by erosion', () {
      final src = Uint8List.fromList([
        10, 20, 30, 128, 40, 50, 60, 255,
        70, 80, 90, 255, 100, 110, 120, 200,
      ]);
      final out = ComposeEdgeOps.erodeAlpha(
        rgba: src,
        width: 2,
        height: 2,
      );
      expect(out[0], 10);
      expect(out[1], 20);
      expect(out[2], 30);
      expect(out[4], 40);
      expect(out[5], 50);
      expect(out[6], 60);
    });
  });

  group('ComposeEdgeOps.featherAlpha', () {
    test('uniform alpha stays uniform', () {
      final src = Uint8List(4 * 4 * 4);
      for (int i = 3; i < src.length; i += 4) {
        src[i] = 200;
      }
      final out = ComposeEdgeOps.featherAlpha(
        rgba: src,
        width: 4,
        height: 4,
        passes: 2,
      );
      for (int i = 3; i < out.length; i += 4) {
        expect(out[i], 200);
      }
    });

    test('hard edge becomes a gradient', () {
      // 4×1 strip: [0, 0, 255, 255] alpha. One pass → middle pair
      // should blend to values between 0 and 255.
      final src = Uint8List(4 * 1 * 4);
      src[3] = 0;
      src[7] = 0;
      src[11] = 255;
      src[15] = 255;
      final out = ComposeEdgeOps.featherAlpha(
        rgba: src,
        width: 4,
        height: 1,
        passes: 1,
      );
      expect(out[7], greaterThan(0));
      expect(out[7], lessThan(255));
      expect(out[11], greaterThan(0));
      expect(out[11], lessThan(255));
    });

    test('0-pass is identity', () {
      final src = Uint8List.fromList([
        10, 20, 30, 0, 40, 50, 60, 255,
      ]);
      final out = ComposeEdgeOps.featherAlpha(
        rgba: src,
        width: 2,
        height: 1,
        passes: 0,
      );
      expect(out, equals(src));
    });
  });

  group('ComposeEdgeOps.decontaminateEdges', () {
    test('interior pixel (alpha=255) left untouched', () {
      final src = Uint8List.fromList([
        200, 50, 50, 255, // interior — red
      ]);
      final out = ComposeEdgeOps.decontaminateEdges(
        rgba: src,
        width: 1,
        height: 1,
      );
      expect(out[0], 200);
      expect(out[1], 50);
      expect(out[2], 50);
    });

    test('fully transparent pixel left untouched', () {
      final src = Uint8List.fromList([
        123, 45, 67, 0,
      ]);
      final out = ComposeEdgeOps.decontaminateEdges(
        rgba: src,
        width: 1,
        height: 1,
      );
      expect(out[0], 123);
      expect(out[1], 45);
      expect(out[2], 67);
    });

    test('edge pixel (alpha=128) shifts toward interior colour', () {
      // 3×1 strip: interior red at (0), edge green at (1), nothing
      // at (2). The edge pixel should drift toward red.
      final src = Uint8List.fromList([
        220, 40, 40, 255, // interior red
        40, 220, 40, 128, // edge green
        0, 0, 0, 0,
      ]);
      final out = ComposeEdgeOps.decontaminateEdges(
        rgba: src,
        width: 3,
        height: 1,
        radius: 1,
      );
      // Red channel should increase, green should decrease.
      expect(out[4], greaterThan(40));
      expect(out[5], lessThan(220));
    });

    test('strength=0 is a no-op across every edge pixel', () {
      final src = Uint8List.fromList([
        220, 40, 40, 255,
        40, 220, 40, 128,
      ]);
      final out = ComposeEdgeOps.decontaminateEdges(
        rgba: src,
        width: 2,
        height: 1,
        strength: 0.0,
      );
      expect(out, equals(src));
    });
  });

  group('ComposeEdgeOps.stampContactShadow', () {
    test('empty subject (all alpha=0) returns input unchanged', () {
      final src = Uint8List(10 * 10 * 4);
      final out = ComposeEdgeOps.stampContactShadow(
        rgba: src,
        width: 10,
        height: 10,
      );
      expect(out, equals(src));
    });

    test('shadow stamps transparent pixels below the subject', () {
      // 20×20 image, subject = 5×5 opaque block at (5..10, 5..10).
      const w = 20;
      const h = 20;
      final src = Uint8List(w * h * 4);
      for (int y = 5; y <= 10; y++) {
        for (int x = 5; x <= 10; x++) {
          final i = (y * w + x) * 4;
          src[i] = 200;
          src[i + 1] = 100;
          src[i + 2] = 50;
          src[i + 3] = 255;
        }
      }
      final out = ComposeEdgeOps.stampContactShadow(
        rgba: src,
        width: w,
        height: h,
      );
      // Below the subject (y > 10) we expect at least one pixel to
      // have gained alpha from the shadow.
      int shadowPixels = 0;
      for (int y = 11; y < h; y++) {
        for (int x = 0; x < w; x++) {
          final a = out[(y * w + x) * 4 + 3];
          if (a > 0) shadowPixels++;
        }
      }
      expect(shadowPixels, greaterThan(0));
    });

    test('shadow does not darken pixels inside the subject', () {
      const w = 20;
      const h = 20;
      final src = Uint8List(w * h * 4);
      for (int y = 5; y <= 10; y++) {
        for (int x = 5; x <= 10; x++) {
          final i = (y * w + x) * 4;
          src[i] = 200;
          src[i + 1] = 100;
          src[i + 2] = 50;
          src[i + 3] = 255;
        }
      }
      final out = ComposeEdgeOps.stampContactShadow(
        rgba: src,
        width: w,
        height: h,
      );
      for (int y = 5; y <= 10; y++) {
        for (int x = 5; x <= 10; x++) {
          final i = (y * w + x) * 4;
          expect(out[i], 200, reason: 'interior red at ($x, $y) unchanged');
          expect(out[i + 3], 255);
        }
      }
    });

    test('opacity=0 disables the shadow', () {
      final src = Uint8List(100);
      for (int i = 3; i < src.length; i += 4) {
        src[i] = 200;
      }
      final out = ComposeEdgeOps.stampContactShadow(
        rgba: src,
        width: 5,
        height: 5,
        opacity: 0.0,
      );
      expect(out, equals(src));
    });
  });
}
