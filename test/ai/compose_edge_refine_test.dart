import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:image_editor/ai/services/compose_on_bg/compose_edge_refine.dart';

/// Phase XVI.15: the edge-refine pipeline that backs the compose-
/// subject Feather / Decontaminate sliders. Pure CPU math — these
/// tests exercise the two ops (decontaminate + alpha box blur +
/// premultiply) without going through Flutter's image codec.
void main() {
  group('ComposeEdgeRefine.apply — zero params', () {
    test('zero feather + zero decontam = just premultiplied input', () {
      // Pattern: a 2×1 image with one opaque white and one half-alpha
      // magenta. Premul should halve the magenta's RGB.
      final input = Uint8List.fromList([
        255, 255, 255, 255, // pixel 0: opaque white
        255, 0, 255, 128, //   pixel 1: half-alpha magenta, rgb unchanged
      ]);
      final out = ComposeEdgeRefine.apply(
        straightRgba: input,
        width: 2,
        height: 1,
        featherPx: 0,
        decontamStrength: 0,
      );
      expect(out[0], 255);
      expect(out[1], 255);
      expect(out[2], 255);
      expect(out[3], 255);
      // 255 * 128 / 255 = 128
      expect(out[4], 128);
      expect(out[5], 0);
      expect(out[6], 128);
      expect(out[7], 128);
    });

    test('zero-alpha pixel RGB is wiped during premultiply', () {
      // Input: single pixel with garbage RGB at α=0 — the halo source
      // the premul step specifically zeros out.
      final input = Uint8List.fromList([255, 255, 255, 0]);
      final out = ComposeEdgeRefine.apply(
        straightRgba: input,
        width: 1,
        height: 1,
        featherPx: 0,
        decontamStrength: 0,
      );
      expect(out[0], 0);
      expect(out[1], 0);
      expect(out[2], 0);
      expect(out[3], 0);
    });
  });

  group('ComposeEdgeRefine.apply — feather', () {
    test('box blur softens a sharp α edge', () {
      // A 5×1 image with a hard α transition at the middle. After a
      // radius-1 feather, the middle pixel's α should fall between 0
      // and 255 (proof the blur actually smoothed the step).
      final input = Uint8List(5 * 4);
      for (int x = 0; x < 5; x++) {
        final a = x < 2 ? 0 : 255;
        final i = x * 4;
        // Non-zero RGB inside the alpha band so we can also verify
        // RGB stays untouched by the α-only blur.
        input[i] = 200;
        input[i + 1] = 100;
        input[i + 2] = 50;
        input[i + 3] = a;
      }
      final out = ComposeEdgeRefine.apply(
        straightRgba: input,
        width: 5,
        height: 1,
        featherPx: 1,
        decontamStrength: 0,
      );
      // Centre pixel used to be α=255 (first of opaque run). After a
      // 3-tap box blur it averages [0, 255, 255]/3 ≈ 170.
      expect(out[2 * 4 + 3], lessThan(255));
      expect(out[2 * 4 + 3], greaterThan(0));
      // Left-edge pixel should have picked up some α from its
      // opaque neighbour.
      expect(out[1 * 4 + 3], greaterThan(0));
    });

    test('uniform α is invariant under feather', () {
      // Blurring a flat α=200 patch should leave it at ~200 every-
      // where (small rounding drift at the clamped border is fine).
      final input = Uint8List(10 * 4);
      for (int p = 0; p < 10; p++) {
        final i = p * 4;
        input[i] = 128;
        input[i + 1] = 128;
        input[i + 2] = 128;
        input[i + 3] = 200;
      }
      final out = ComposeEdgeRefine.apply(
        straightRgba: input,
        width: 10,
        height: 1,
        featherPx: 2,
        decontamStrength: 0,
      );
      for (int p = 0; p < 10; p++) {
        // Non-premul α should be 200 ± 1. The premul step scales RGB
        // by α but leaves α alone, so 200 stays 200.
        expect(out[p * 4 + 3], inInclusiveRange(199, 201));
      }
    });
  });

  group('ComposeEdgeRefine.apply — decontaminate', () {
    test('semi-transparent edge pixel is pulled toward interior', () {
      // 3×1: opaque red  |  semi-transparent green (the fringe)  |
      //      opaque red. With decontam=1.0, the green should be
      // pulled toward red.
      final input = Uint8List.fromList([
        255, 0, 0, 255,   // opaque red
        0, 255, 0, 100,   // fringe: green at α=100 (below threshold)
        255, 0, 0, 255,   // opaque red
      ]);
      final out = ComposeEdgeRefine.apply(
        straightRgba: input,
        width: 3,
        height: 1,
        featherPx: 0,
        decontamStrength: 1.0,
      );
      // After decontam, fringe RGB should lean red. After premul,
      // red should still be the dominant channel (R > G).
      // α=100, so premul scales by 100/255 ≈ 0.39.
      final r = out[4];
      final g = out[5];
      expect(r, greaterThan(g),
          reason: 'decontaminate should pull green edge toward red');
      expect(out[7], 100, reason: 'alpha untouched by decontaminate');
    });

    test('zero strength = decontaminate is a no-op on RGB', () {
      // Same setup as above but with strength 0 — the semi-transparent
      // pixel's RGB should only change from the premul, not from any
      // colour pull.
      final input = Uint8List.fromList([
        255, 0, 0, 255,
        0, 255, 0, 100,
        255, 0, 0, 255,
      ]);
      final out = ComposeEdgeRefine.apply(
        straightRgba: input,
        width: 3,
        height: 1,
        featherPx: 0,
        decontamStrength: 0.0,
      );
      // premul: 0 * 100 / 255 = 0 for R and B, 255 * 100 / 255 = 100
      // for G. Colour character unchanged (still green-dominant).
      expect(out[4], 0);
      expect(out[5], 100);
      expect(out[6], 0);
    });
  });
}
