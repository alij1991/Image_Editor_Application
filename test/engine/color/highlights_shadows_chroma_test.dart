import 'package:flutter_test/flutter_test.dart';

import 'package:image_editor/engine/color/highlights_shadows_math.dart';

/// Phase XVI.25 — pin the chroma-preservation invariant on the
/// highlights / shadows / whites / blacks shader.
///
/// Pre-XVI.25 the shader added `vec3(delta)` directly to `src.rgb`,
/// which desaturated saturated colours under positive shadow lifts
/// (a `(1, 0, 0)` red pixel under `shadows = +0.5` became
/// `(1, 0.25, 0.25)` — washed-out pink with the hue shifted halfway
/// to gray). The new math operates on perceptual Y and scales the
/// source RGB by `Ynew / Y` so the chroma direction stays intact.
///
/// These tests pin the invariant. They do NOT exercise the GLSL —
/// `HighlightsShadowsMath` is the canonical mirror; the shader
/// duplicates the formula verbatim and the audit dispatcher reviews
/// any drift.
void main() {
  group('HighlightsShadowsMath chroma preservation (XVI.25)', () {
    test('identity sliders return the source unchanged', () {
      final result = HighlightsShadowsMath.applyRgb(r: 0.7, g: 0.3, b: 0.1);
      expect(result[0], closeTo(0.7, 1e-9));
      expect(result[1], closeTo(0.3, 1e-9));
      expect(result[2], closeTo(0.1, 1e-9));
    });

    test('saturated red under shadows=+0.5 keeps its hue', () {
      // Pre-XVI.25: red turned pink. Post-XVI.25 the chroma
      // direction is preserved, so the hue stays at red (~0°).
      final out = HighlightsShadowsMath.applyRgb(
        r: 1.0,
        g: 0.0,
        b: 0.0,
        shadows: 0.5,
      );
      // Red channel hits the ceiling at 1.0; green / blue stay
      // near zero — the chroma direction (1, 0, 0) is preserved
      // up to multiplicative scaling.
      expect(out[0], closeTo(1.0, 1e-3));
      expect(out[1], lessThan(0.01),
          reason: 'shadow lift must NOT push green into the red pixel '
              '— that desaturates the colour');
      expect(out[2], lessThan(0.01),
          reason: 'shadow lift must NOT push blue into the red pixel '
              '— that desaturates the colour');
      // Hue is undefined when delta is tiny; we just assert the
      // direction is still pure red by checking g/b are near-zero
      // above. The pre-fix output `(1, 0.25, 0.25)` would fail
      // the green / blue assertions.
    });

    test('saturated red under shadows=+0.5 has no measurable hue shift',
        () {
      final out = HighlightsShadowsMath.applyRgb(
        r: 1.0,
        g: 0.0,
        b: 0.0,
        shadows: 0.5,
      );
      final hueIn = HighlightsShadowsMath.hue(1.0, 0.0, 0.0)!;
      final hueOut = HighlightsShadowsMath.hue(out[0], out[1], out[2]);
      // Hue may be null when the colour clamps to black/white, but
      // for our saturated-red test the chroma is preserved.
      expect(hueOut, isNotNull);
      // Within 1° tolerance — the original hue is 0°; any drift
      // > 1° means we're picking up green or blue contamination.
      expect((hueOut! - hueIn).abs(), lessThan(1.0),
          reason: 'hue must not drift more than 1° under a shadow lift');
    });

    test('mid-saturation blue under highlights=-0.5 keeps its hue', () {
      // Highlights pull-down on a near-white blue should darken the
      // blue without shifting toward yellow.
      const inR = 0.6, inG = 0.6, inB = 0.95;
      final hueIn = HighlightsShadowsMath.hue(inR, inG, inB)!;
      final out = HighlightsShadowsMath.applyRgb(
        r: inR,
        g: inG,
        b: inB,
        highlights: -0.5,
      );
      final hueOut = HighlightsShadowsMath.hue(out[0], out[1], out[2]);
      expect(hueOut, isNotNull);
      expect((hueOut! - hueIn).abs(), lessThan(2.0),
          reason: 'highlights drop on a saturated blue must not shift '
              'the hue toward yellow');
    });

    test('pure black under blacks=+0.5 still lifts (additive fallback)',
        () {
      // Multiplicative scaling can't introduce colour from nothing
      // — a pure-black pixel would stay black under `rgb * ratio`
      // because every channel is 0. The math falls back to additive
      // when Y <= epsilon so the slider still has a visible effect on
      // black frames. (Note: the `shadows` mask only covers the
      // [0.10, 0.50] band, so pure-black sits in the `blacks` band
      // — that's the slider that actually fires here.)
      final out = HighlightsShadowsMath.applyRgb(
        r: 0,
        g: 0,
        b: 0,
        blacks: 0.5,
      );
      expect(out[0], greaterThan(0.0));
      expect(out[1], closeTo(out[0], 1e-9));
      expect(out[2], closeTo(out[0], 1e-9));
    });

    test(
        'pure black under shadows=+0.5 stays black — masks are non-'
        'overlapping by design', () {
      // Sanity check on the band geometry: the `shadows` mask is
      // smoothstep(0.05, 0.20, Y) * (1 - smoothstep(0.35, 0.55, Y)),
      // so at Y=0 the mask is 0 and a shadow lift has no effect.
      // The dedicated `blacks` slider covers the deep-shadow band.
      final out = HighlightsShadowsMath.applyRgb(
        r: 0,
        g: 0,
        b: 0,
        shadows: 0.5,
      );
      expect(out[0], 0.0);
      expect(out[1], 0.0);
      expect(out[2], 0.0);
    });

    test('output stays clamped to [0, 1] under aggressive lift', () {
      // shadows=+1, blacks=+1, highlights=+1, whites=+1 on a mid-
      // tone red pushes the clipped channel to the ceiling.
      final out = HighlightsShadowsMath.applyRgb(
        r: 0.8,
        g: 0.2,
        b: 0.2,
        highlights: 1.0,
        shadows: 1.0,
        whites: 1.0,
        blacks: 1.0,
      );
      for (final v in out) {
        expect(v, greaterThanOrEqualTo(0.0));
        expect(v, lessThanOrEqualTo(1.0));
      }
    });
  });

  group('HighlightsShadowsMath.hue (helper sanity)', () {
    test('pure red is hue 0', () {
      expect(HighlightsShadowsMath.hue(1, 0, 0), closeTo(0, 1e-6));
    });
    test('pure green is hue 120', () {
      expect(HighlightsShadowsMath.hue(0, 1, 0), closeTo(120, 1e-6));
    });
    test('pure blue is hue 240', () {
      expect(HighlightsShadowsMath.hue(0, 0, 1), closeTo(240, 1e-6));
    });
    test('grayscale returns null', () {
      expect(HighlightsShadowsMath.hue(0.5, 0.5, 0.5), isNull);
    });
  });
}
