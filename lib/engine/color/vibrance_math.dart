import 'dart:math' as math;

/// Pure-Dart mirror of the math in `shaders/vibrance.frag`. The
/// shader's vibrance computation is reproduced here so it can be
/// regression-tested without a real GPU fixture, and so call sites
/// that need to predict the slider's behaviour (preset thumbnails,
/// future auto-tone heuristics) can call into the same canonical
/// formula.
///
/// ## Phase XVI.26 — skin-tone protect
///
/// Lightroom's vibrance algorithm attenuates the saturation boost in
/// the orange-red hue band (skin tones) so faces don't go neon under
/// a +1 vibrance slider. The attenuation is a cosine-weighted mask
/// centred at hue ≈ 25° with ≈ 30° half-width. Inside the band the
/// effective vibrance is halved at peak; outside the band it is the
/// full slider amount. Same math runs both Dart-side and GLSL-side
/// — keep both in sync.
class VibranceMath {
  VibranceMath._();

  /// Skin centre hue in degrees. 25° is the perceptual middle of the
  /// orange-red band that Caucasian / olive / brown skin reflectance
  /// sits inside on a calibrated display. Lightroom uses ~20° based on
  /// public reverse-engineering; 25° is a slight bias toward warmer
  /// tones that matches most phone-camera skin renders.
  static const double skinHueCenterDeg = 25.0;

  /// Half-width of the skin-tone band. Outside `skinHueCenterDeg ±
  /// skinHueHalfWidthDeg` the mask is 0 (no attenuation); inside, the
  /// cosine taper rises to 1.0 at the centre.
  static const double skinHueHalfWidthDeg = 30.0;

  /// Maximum attenuation depth at the skin-band centre. 0.5 means a
  /// pure-skin pixel sees half the vibrance amount; 1.0 would mean
  /// "no vibrance at all on skin." Lightroom's UX is closer to 0.5 —
  /// users still want skin to gain *some* saturation pop on a +1
  /// slider, just not the eye-melting amount cyan or red would get.
  static const double skinAttenuationDepth = 0.5;

  /// Apply vibrance to a single linear-sRGB-encoded RGB triple.
  /// All values are in `[0, 1]` and the slider is in `[-1, 1]` with
  /// identity at `0`. Output is clamped to `[0, 1]`.
  static List<double> applyRgb({
    required double r,
    required double g,
    required double b,
    double vibrance = 0,
  }) {
    if (vibrance == 0) {
      return [r.clamp(0.0, 1.0), g.clamp(0.0, 1.0), b.clamp(0.0, 1.0)];
    }
    final maxC = math.max(r, math.max(g, b));
    final minC = math.min(r, math.min(g, b));
    final sat = maxC - minC;

    // Skin-protect: attenuate the boost when the hue sits in the
    // orange-red band. Achromatic / near-grey pixels skip the mask
    // because their hue is undefined.
    final hueDeg = _hueDegOrNull(r, g, b, sat);
    final skinMask = hueDeg == null ? 0.0 : _skinMask(hueDeg);
    final effectiveVibrance = vibrance * (1.0 - skinAttenuationDepth * skinMask);

    final scale =
        (1.0 + effectiveVibrance * 1.5 * (1.0 - sat)).clamp(0.0, 2.5);
    final lum = 0.2126 * r + 0.7152 * g + 0.0722 * b;
    final outR = lum + (r - lum) * scale;
    final outG = lum + (g - lum) * scale;
    final outB = lum + (b - lum) * scale;
    return [
      outR.clamp(0.0, 1.0),
      outG.clamp(0.0, 1.0),
      outB.clamp(0.0, 1.0),
    ];
  }

  /// Cosine-weighted skin-tone hue mask. Returns 1.0 at the centre,
  /// 0.0 at the band edges, with a smooth `cos(angle * π/2)` taper.
  /// Outside the band the mask is exactly 0.
  static double _skinMask(double hueDeg) {
    var dh = (hueDeg - skinHueCenterDeg).abs();
    if (dh > 180) dh = 360 - dh; // shortest arc on the hue wheel
    if (dh >= skinHueHalfWidthDeg) return 0.0;
    return math.cos(dh / skinHueHalfWidthDeg * (math.pi / 2));
  }

  /// Public mask helper — same math as the private taper, exposed
  /// for tests + future call sites that want to reuse the curve.
  static double skinMaskForHue(double hueDeg) => _skinMask(hueDeg);

  static double? _hueDegOrNull(double r, double g, double b, double sat) {
    if (sat < 1e-4) return null;
    final maxC = math.max(r, math.max(g, b));
    double h;
    if (maxC == r) {
      h = ((g - b) / sat) % 6;
    } else if (maxC == g) {
      h = ((b - r) / sat) + 2;
    } else {
      h = ((r - g) / sat) + 4;
    }
    h *= 60;
    if (h < 0) h += 360;
    return h;
  }
}
