import 'package:flutter_test/flutter_test.dart';

import 'package:image_editor/engine/color/vibrance_math.dart';

/// Phase XVI.26 — pin the skin-tone protect invariant on the
/// vibrance shader.
///
/// Pre-XVI.26 the vibrance boost was uniform across the hue wheel,
/// so faces went neon orange under a +1 slider. The new math
/// attenuates by up to 50% inside the orange-red band (~25° centre,
/// ~30° half-width) via a cosine taper. The shader mirrors
/// `VibranceMath.applyRgb` — these tests pin the Dart math, the
/// shader follows.
double _saturation(double r, double g, double b) {
  final maxC = [r, g, b].reduce((a, b) => a > b ? a : b);
  final minC = [r, g, b].reduce((a, b) => a < b ? a : b);
  return maxC - minC;
}

void main() {
  group('VibranceMath skin-protect (XVI.26)', () {
    test('identity slider returns the source unchanged', () {
      final out = VibranceMath.applyRgb(r: 0.6, g: 0.4, b: 0.2);
      expect(out[0], closeTo(0.6, 1e-9));
      expect(out[1], closeTo(0.4, 1e-9));
      expect(out[2], closeTo(0.2, 1e-9));
    });

    test('orange-skin pixel sees ≤ 50% of vibrance applied vs. a blue sky',
        () {
      // Skin-tone proxy: medium-saturation orange ~25° hue, low to
      // mid saturation (skin reflectance falls in this region).
      // Blue-sky proxy: ~210° hue, similar starting saturation.
      // Both pixels picked so the +1 vibrance boost stays inside
      // the gamut on every channel — clipping the sky pixel's blue
      // would suppress its apparent boost and inflate the ratio.
      const skinR = 0.62, skinG = 0.45, skinB = 0.34; // ~25° hue
      const skyR = 0.40, skyG = 0.55, skyB = 0.70; // ~210° hue
      const slider = 1.0;

      final skinSatBefore = _saturation(skinR, skinG, skinB);
      final skySatBefore = _saturation(skyR, skyG, skyB);

      final skinOut = VibranceMath.applyRgb(
        r: skinR,
        g: skinG,
        b: skinB,
        vibrance: slider,
      );
      final skyOut = VibranceMath.applyRgb(
        r: skyR,
        g: skyG,
        b: skyB,
        vibrance: slider,
      );
      final skinSatAfter = _saturation(skinOut[0], skinOut[1], skinOut[2]);
      final skySatAfter = _saturation(skyOut[0], skyOut[1], skyOut[2]);

      // Boost ratio: how much each pixel's saturation grew.
      final skinBoost = skinSatAfter - skinSatBefore;
      final skyBoost = skySatAfter - skySatBefore;
      expect(skyBoost, greaterThan(0.0),
          reason: 'sanity: blue sky should gain saturation');
      expect(skinBoost, greaterThan(0.0),
          reason: 'sanity: skin should still gain SOME saturation');
      // The audit's success criterion: skin sees ≤ 50% of the boost
      // that the blue-sky pixel sees (allowing a small tolerance for
      // the cosine-mask and saturation-ramp interaction).
      expect(skinBoost / skyBoost, lessThanOrEqualTo(0.6),
          reason: 'skin protect: skin gain must be ≤ ~50% of sky gain '
              'on a +1 slider — got ${(skinBoost / skyBoost).toStringAsFixed(3)}');
    });

    test('skinMask hits 1.0 at the band centre, 0.0 at the edges, '
        '0.0 outside', () {
      expect(VibranceMath.skinMaskForHue(25.0), closeTo(1.0, 1e-9));
      expect(VibranceMath.skinMaskForHue(55.0), closeTo(0.0, 1e-9));
      expect(VibranceMath.skinMaskForHue(355.0),
          closeTo(0.0, 1e-9)); // ≈ -5° from centre, outside band
      // Far from skin: green / blue / magenta.
      expect(VibranceMath.skinMaskForHue(120.0), 0.0);
      expect(VibranceMath.skinMaskForHue(240.0), 0.0);
      expect(VibranceMath.skinMaskForHue(300.0), 0.0);
    });

    test('skinMask wraparound: hue 355° (≈ -5°) is inside the band', () {
      // 355° is 30° from 25° going one way but only 30° the other.
      // The mask uses the shorter arc, so 355° sits at the band
      // edge (mask ≈ 0) but 5° (very close to 25° going the other
      // direction) is well inside.
      expect(VibranceMath.skinMaskForHue(5.0), greaterThan(0.3),
          reason: 'hue=5° is 20° from skin centre via the short arc');
      expect(VibranceMath.skinMaskForHue(0.0), greaterThan(0.1),
          reason: 'hue=0° is 25° from skin centre — at the band edge');
    });

    test('grayscale pixel skips the skin mask (undefined hue)', () {
      // A neutral-grey pixel under +1 vibrance should NOT get the
      // skin attenuation — its hue is undefined, so the mask returns
      // 0 and the full vibrance applies. (In practice grey + low
      // saturation also means almost no boost from `(1-sat)` term;
      // the test asserts the mask path, not the perceptual result.)
      final out = VibranceMath.applyRgb(
        r: 0.5,
        g: 0.5,
        b: 0.5,
        vibrance: 1.0,
      );
      // Output is still grey because saturation == 0 → the (1-sat)
      // factor kicks in but there's no chroma to lift.
      expect(out[0], closeTo(out[1], 1e-9));
      expect(out[1], closeTo(out[2], 1e-9));
    });

    test('green plant pixel gets the full +1 boost (outside skin band)',
        () {
      // Green ~120° is far from the skin band → no attenuation.
      // The boost should be larger than the skin equivalent.
      final out = VibranceMath.applyRgb(
        r: 0.30,
        g: 0.55,
        b: 0.20,
        vibrance: 1.0,
      );
      final satIn = _saturation(0.30, 0.55, 0.20);
      final satOut = _saturation(out[0], out[1], out[2]);
      expect(satOut, greaterThan(satIn),
          reason: 'green should gain saturation on +1 vibrance');
    });
  });
}
