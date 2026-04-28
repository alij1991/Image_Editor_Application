import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:image_editor/ai/services/compose_on_bg/compose_edge_refine.dart';

/// Phase XVI.15 → XVI.20: the edge-refine pipeline that backs the
/// compose-subject "Soften edges" slider. Pure CPU math — these tests
/// exercise the feather pass plus the bundled internal decontaminate
/// pass without going through Flutter's image codec.
///
/// XVI.20 dropped the user-facing Decontaminate slider, so the tests
/// no longer parametrise it; instead the decontam-coverage tests
/// drive feather > 0 and assert the same fringe-cleanup behaviour
/// the slider used to drive at strength=1.0.
void main() {
  group('ComposeEdgeRefine.apply — zero feather', () {
    test('zero feather = just premultiplied input', () {
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
      );
      expect(out[0], 0);
      expect(out[1], 0);
      expect(out[2], 0);
      expect(out[3], 0);
    });
  });

  group('ComposeEdgeRefine.apply — feather', () {
    test('box blur softens a sharp α edge (outward only — XVI.19)', () {
      // A 5×1 image with a hard α transition at the middle. After the
      // XVI.19 interior-preserving feather, the original α=255 pixels
      // stay at α=255 (sharp interior), but the α=0 pixels adjacent
      // to them pick up partial α from the blur — the ring spreads
      // OUTWARD rather than eating into the interior.
      final input = Uint8List(5 * 4);
      for (int x = 0; x < 5; x++) {
        final a = x < 2 ? 0 : 255;
        final i = x * 4;
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
      );
      // Interior pixel 2 (originally α=255) must stay α=255 — the
      // XVI.18 regression where the whole subject blurred came from
      // this assertion being `lessThan(255)`.
      expect(out[2 * 4 + 3], 255,
          reason: 'interior α must survive the feather intact');
      // Pixel 1 (originally α=0) picks up partial α from the ring.
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
      );
      for (int p = 0; p < 10; p++) {
        // Non-premul α should be 200 ± 1. The premul step scales RGB
        // by α but leaves α alone, so 200 stays 200.
        expect(out[p * 4 + 3], inInclusiveRange(199, 201));
      }
    });
  });

  group('ComposeEdgeRefine.apply — internal decontaminate (XVI.20)', () {
    test(
        'feather > 0 silently runs decontaminate on the native '
        'RVM 0<α<240 fringe', () {
      // 3×1: opaque red | semi-transparent green (the fringe at α=100)
      // | opaque red. Without decontam, the green stays green and the
      // feather just blurs around it. With XVI.20's bundled internal
      // decontam, the green RGB is replaced with the α-weighted
      // neighbour average BEFORE feather — so the post-bake fringe
      // leans red instead of staying green.
      final input = Uint8List.fromList([
        255, 0, 0, 255, //   opaque red
        0, 255, 0, 100, //   fringe: green at α=100 (below threshold)
        255, 0, 0, 255, //   opaque red
      ]);
      final out = ComposeEdgeRefine.apply(
        straightRgba: input,
        width: 3,
        height: 1,
        featherPx: 1, // any non-zero feather triggers internal decontam
      );
      // After decontam pulls the fringe toward red, the feather
      // composite, then the final premul, the fringe pixel's R
      // channel should clearly dominate G.
      final r = out[4];
      final g = out[5];
      expect(r, greaterThan(g),
          reason:
              'XVI.20 internal decontam should pull green fringe toward red');
    });

    test('zero feather skips the internal decontam (no surprise mutation)',
        () {
      // Same fringe pattern but featherPx=0 — XVI.20 explicitly
      // collapses to "zero contam preprocess + final premul" so the
      // cached default bake stays stable bit-for-bit. The fringe
      // pixel's RGB character must be unchanged from the pure-premul
      // baseline (still green-dominant, just darkened by α/255).
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
        'feather on contaminated α=0 produces clean FG fringe, '
        'not original-bg halo (XVI.20 internal decontam)', () {
      // Scenario the user hit: the subject is a 3×1 matte with a clean
      // blue interior and bright magenta "contamination" (original
      // photo's background) baked into the α=0 pixels flanking it.
      // After feather (which now bundles internal decontam in XVI.20)
      // we expect the feathered ring to pick up BLUE (interior FG
      // colour), not MAGENTA (contamination).
      final input = Uint8List.fromList([
        255, 0, 255, 0, //   contaminated α=0 magenta
        0, 0, 255, 255, //   clean blue subject pixel
        255, 0, 255, 0, //   contaminated α=0 magenta
      ]);
      final out = ComposeEdgeRefine.apply(
        straightRgba: input,
        width: 3,
        height: 1,
        featherPx: 1,
      );
      // Left neighbour of the subject: previously α=0 magenta,
      // should now be semi-transparent blue after feather pulled α
      // up and the zero-contam preprocess wiped its magenta RGB.
      expect(out[3], greaterThan(0),
          reason: 'feather should have raised left pixel\'s α above 0');
      // Blue channel (index 2) must dominate over red (0) — i.e.
      // the fringe is blue-tinted, not magenta-tinted.
      expect(out[2], greaterThan(out[0]),
          reason:
              'fringe RGB should pull toward blue interior, not preserve '
              'the magenta contamination');
    });

    test(
        'wide feather (9 px) inpaints the ring with interior colour '
        '(XVI.18 premul-blur fix)', () {
      // The XVI.17 bug: decontam's 5×5 sample window couldn't reach
      // interior pixels when feather widened the ring to ≥ 3 px, so
      // the ring silently stayed black. XVI.18 replaced the per-pixel
      // window decontam with a premultiplied box blur that gives
      // interior colour everywhere the kernel touches an interior
      // pixel, regardless of ring width.
      //
      // Image: 19×1 with a single clean-blue interior pixel in the
      // middle and contaminated yellow on both sides. Feather = 4
      // expands the matte ring to 9 px — well beyond a 5×5 window.
      const w = 19;
      final input = Uint8List(w * 4);
      for (int x = 0; x < w; x++) {
        final i = x * 4;
        if (x == w ~/ 2) {
          input[i] = 0; // R
          input[i + 1] = 0; // G
          input[i + 2] = 255; // B — interior blue
          input[i + 3] = 255;
        } else {
          input[i] = 255; // contamination: bright yellow
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
      );
      // Inspect the pixel 3 positions left of centre — clearly inside
      // the feathered ring, far from decontam's old 5×5 reach.
      const idx = (w ~/ 2 - 3) * 4;
      // Blue channel must dominate over the contamination's yellow
      // (R+G) — confirms the premul blur pulled interior colour
      // across the whole ring.
      expect(out[idx + 3], greaterThan(0),
          reason: 'feather should have raised α into this pixel');
      expect(out[idx + 2], greaterThan(0),
          reason: 'blue from interior should have bled here via '
              'premultiplied blur');
      expect(out[idx] + out[idx + 1], lessThan(out[idx + 2] * 2 + 40),
          reason: 'yellow contamination (R+G) must not dominate — '
              'if this fires the old "decontam window too small" '
              'regression is back');
    });

    test(
        'XVI.19 interior preservation — α=255 pixels keep their '
        'original RGB through a strong feather', () {
      // Regression test for the "blurred face" report: before XVI.19
      // the premul-blur smeared interior pixels (hair→face→clothes).
      // After XVI.19 every α=255 pixel must survive the feather with
      // its exact input RGB and α=255.
      const w = 15;
      // Solid 5-pixel interior in the middle, α=0 on the flanks.
      final input = Uint8List(w * 4);
      for (int x = 0; x < w; x++) {
        final i = x * 4;
        final inside = x >= 5 && x <= 9;
        // Each interior pixel has a DIFFERENT RGB so we can detect
        // smearing (blur would average them to a mid tone).
        input[i] = inside ? (x * 40 % 256) : 0;
        input[i + 1] = inside ? ((x * 70) % 256) : 0;
        input[i + 2] = inside ? ((x * 110) % 256) : 0;
        input[i + 3] = inside ? 255 : 0;
      }
      final out = ComposeEdgeRefine.apply(
        straightRgba: input,
        width: w,
        height: 1,
        featherPx: 6,
      );
      for (int x = 5; x <= 9; x++) {
        final i = x * 4;
        // Each interior pixel should still have its unique input RGB
        // (after the final premul, but α=255 means × 1 → unchanged).
        expect(out[i], input[i],
            reason: 'interior pixel $x R smeared — XVI.19 regression');
        expect(out[i + 1], input[i + 1],
            reason: 'interior pixel $x G smeared — XVI.19 regression');
        expect(out[i + 2], input[i + 2],
            reason: 'interior pixel $x B smeared — XVI.19 regression');
        expect(out[i + 3], 255,
            reason: 'interior pixel $x α dropped — XVI.19 regression');
      }
    });

    test(
        'feather alone produces clean FG fringe '
        '(XVI.18 premul blur + XVI.20 internal decontam)', () {
      // Combined regression: feather on a tiny clean subject flanked
      // by α=0 contamination should produce a teal-tinted ring, not
      // a yellow halo carried over from the original bg.
      final input = Uint8List.fromList([
        255, 255, 0, 0, //   contaminated α=0 yellow
        0, 128, 200, 255, // clean teal subject pixel
        255, 255, 0, 0, //   contaminated α=0 yellow
      ]);
      final out = ComposeEdgeRefine.apply(
        straightRgba: input,
        width: 3,
        height: 1,
        featherPx: 1,
      );
      // Left neighbour should have SOME colour from the interior
      // teal — green or blue channel non-trivial, red channel small.
      // Without the zero-contam preprocess + premul blur, all three
      // channels would carry the yellow halo.
      expect(out[3], greaterThan(0), reason: 'feather raised α above 0');
      expect(out[1] + out[2], greaterThan(out[0]),
          reason: 'teal pulled into the fringe instead of magenta/yellow halo');
    });
  });
}
