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

  group('ComposeEdgeRefine.apply — XVI.17 reorder regression', () {
    test(
        'feather+decontam on contaminated α=0 produces clean FG fringe, '
        'not original-bg halo', () {
      // Scenario the user hit: the subject is a 3×1 matte with a clean
      // blue interior and bright magenta "contamination" (original
      // photo's background) baked into the α=0 pixels flanking it.
      // After feather + decontam we expect the feathered ring to pick
      // up BLUE (interior FG colour), not MAGENTA (contamination).
      // Pre-XVI.17 ordering (decontam → feather → premul) left the
      // contaminated magenta in the widened ring; the reorder is what
      // this test pins.
      final input = Uint8List.fromList([
        255, 0, 255, 0,   // contaminated α=0 magenta
        0, 0, 255, 255,   // clean blue subject pixel
        255, 0, 255, 0,   // contaminated α=0 magenta
      ]);
      final out = ComposeEdgeRefine.apply(
        straightRgba: input,
        width: 3,
        height: 1,
        featherPx: 1,
        decontamStrength: 1.0,
      );
      // Left neighbour of the subject: previously α=0 magenta,
      // should now be semi-transparent blue after feather pulled α
      // up and decontam pulled RGB toward the blue interior.
      expect(out[3], greaterThan(0),
          reason: 'feather should have raised left pixel\'s α above 0');
      // Blue channel (index 2) must dominate over red (0) — i.e.
      // the fringe is blue-tinted, not magenta-tinted.
      expect(out[2], greaterThan(out[0]),
          reason: 'decontam should pull fringe RGB toward blue interior, '
              'not preserve the magenta contamination');
    });

    test(
        'wide feather (9 px) inpaints the ring with interior colour '
        'even at decontam=0 — XVI.18 premul-blur fix', () {
      // The XVI.17 bug: decontam's 5×5 sample window couldn't reach
      // interior pixels when feather widened the ring to ≥ 3 px, so
      // the ring silently stayed black. XVI.18 replaced the per-pixel
      // window decontam with a premultiplied box blur that gives
      // interior colour everywhere the kernel touches an interior
      // pixel, regardless of ring width. This test pins that.
      //
      // Image: 19×1 with a single clean-blue interior pixel in the
      // middle and contaminated yellow on both sides. Feather = 4
      // expands the matte ring to 9 px — well beyond a 5×5 window.
      const w = 19;
      final input = Uint8List(w * 4);
      for (int x = 0; x < w; x++) {
        final i = x * 4;
        if (x == w ~/ 2) {
          input[i] = 0;       // R
          input[i + 1] = 0;   // G
          input[i + 2] = 255; // B — interior blue
          input[i + 3] = 255;
        } else {
          input[i] = 255;     // contamination: bright yellow
          input[i + 1] = 255;
          input[i + 2] = 0;
          input[i + 3] = 0;
        }
      }
      final out = ComposeEdgeRefine.apply(
        straightRgba: input,
        width: w,
        height: 1,
        featherPx: 4,
        decontamStrength: 0, // <- decontam off, feather alone must inpaint
      );
      // Inspect the pixel 3 positions left of centre — clearly inside
      // the feathered ring, far from decontam's old 5×5 reach.
      final idx = (w ~/ 2 - 3) * 4;
      // Blue channel must dominate over the contamination's yellow
      // (R+G) — confirms the premul blur pulled interior colour
      // across the whole ring, not the "ring is black/yellow halo"
      // state we had before XVI.18.
      expect(out[idx + 3], greaterThan(0),
          reason: 'feather should have raised α into this pixel');
      expect(out[idx + 2], greaterThan(0),
          reason: 'blue from interior should have bled here via '
              'premultiplied blur');
      expect(out[idx] + out[idx + 1],
          lessThan(out[idx + 2] * 2 + 40),
          reason: 'yellow contamination (R+G) must not dominate — '
              'if this fires the old "decontam window too small" '
              'regression is back');
    });

    test(
        'feather with decontam=0 still produces clean FG fringe '
        '(XVI.18: premul blur does the inpainting)', () {
      // Feather without explicit decontam used to darken the new
      // ring (0 RGB × partial α = black halo). XVI.17 auto-lifts the
      // effective decontam to `kFeatherDecontamFloor` whenever
      // feather > 0 so the ring always blends instead of darkening.
      final input = Uint8List.fromList([
        255, 255, 0, 0,   // contaminated α=0 yellow
        0, 128, 200, 255, // clean teal subject pixel
        255, 255, 0, 0,   // contaminated α=0 yellow
      ]);
      final out = ComposeEdgeRefine.apply(
        straightRgba: input,
        width: 3,
        height: 1,
        featherPx: 1,
        decontamStrength: 0.0, // user set decontam to zero
      );
      // Left neighbour should have SOME colour from the interior
      // teal — green or blue channel non-trivial, red channel small.
      // Without the floor, all three channels would be ~0 (black
      // halo). We only assert a minimum teal character here.
      expect(out[3], greaterThan(0),
          reason: 'feather raised α above 0');
      expect(out[1] + out[2], greaterThan(out[0]),
          reason: 'floor pulled teal into the fringe instead of letting '
              'it render as black');
    });
  });
}
