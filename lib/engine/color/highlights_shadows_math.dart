import 'dart:math' as math;
import 'dart:ui';

/// Pure-Dart mirror of the math in `shaders/highlights_shadows.frag`.
///
/// Exposed so the shader's logic can be tested without a real GPU
/// fixture. The function operates on a single RGB triple and returns
/// the adjusted output. Identity (`highlights = shadows = whites =
/// blacks = 0`) is a passthrough.
///
/// ## Phase XVI.25 — chroma-preserving lift / drop
///
/// Pre-XVI.25 the shader added `vec3(delta)` directly to `src.rgb`,
/// which desaturated saturated colours under positive shadow lifts:
/// a pure-red pixel `(1, 0, 0)` under `shadows = +0.5` became
/// `(1, 0.25, 0.25)` — washed-out pink with the hue shifted toward
/// gray. The new math computes the delta on perceptual Y only and
/// then multiplies the original RGB by `Ynew / Y`, preserving the
/// chroma direction. The "linear-light verify" callout in the audit
/// plan landed on this fix.
class HighlightsShadowsMath {
  HighlightsShadowsMath._();

  /// Rec.709 luma weights — same constants used by the shader.
  static const double _wR = 0.2126;
  static const double _wG = 0.7152;
  static const double _wB = 0.0722;

  /// Apply the highlights/shadows/whites/blacks lift drop to a single
  /// linear-sRGB-encoded RGB triple.
  ///
  /// All sliders are in `[-1, 1]` with identity at `0`. Output is
  /// clamped to `[0, 1]`. The chroma direction of [src] is preserved
  /// when [src] is non-black; pure-black input stays pure black
  /// (multiplicative scaling can't introduce colour).
  static Color apply(
    Color src, {
    double highlights = 0,
    double shadows = 0,
    double whites = 0,
    double blacks = 0,
  }) {
    final r = src.r;
    final g = src.g;
    final b = src.b;
    final adjusted = applyRgb(
      r: r,
      g: g,
      b: b,
      highlights: highlights,
      shadows: shadows,
      whites: whites,
      blacks: blacks,
    );
    return Color.from(
      alpha: src.a,
      red: adjusted[0],
      green: adjusted[1],
      blue: adjusted[2],
    );
  }

  /// Same math as [apply] but operates on raw doubles for tests that
  /// don't want to round-trip through `Color`. Returns
  /// `[r, g, b]`, each clamped to `[0, 1]`.
  static List<double> applyRgb({
    required double r,
    required double g,
    required double b,
    double highlights = 0,
    double shadows = 0,
    double whites = 0,
    double blacks = 0,
  }) {
    final y = _wR * r + _wG * g + _wB * b;

    // Non-overlapping luminance bands — same thresholds as the
    // shader so the visual feel of the sliders is unchanged.
    final blackMask = 1.0 - _smoothstep(0.05, 0.20, y);
    final shadowMask =
        _smoothstep(0.05, 0.20, y) * (1.0 - _smoothstep(0.35, 0.55, y));
    final highlightMask =
        _smoothstep(0.45, 0.65, y) * (1.0 - _smoothstep(0.80, 0.95, y));
    final whiteMask = _smoothstep(0.80, 0.95, y);

    final deltaY = blacks * 0.4 * blackMask +
        shadows * 0.5 * shadowMask +
        highlights * 0.5 * highlightMask +
        whites * 0.4 * whiteMask;

    if (deltaY == 0.0) {
      return [r.clamp(0.0, 1.0), g.clamp(0.0, 1.0), b.clamp(0.0, 1.0)];
    }

    // Chroma-preserving lift: scale RGB by the ratio of the new Y to
    // the original Y so the chroma direction stays intact. Falls back
    // to additive when Y is near-zero (pure black has no chroma to
    // preserve, and dividing by ~0 explodes the ratio).
    final yNew = (y + deltaY).clamp(0.0, 1.0);
    if (y <= 1e-4) {
      // Pure-black input: no direction to preserve. Add deltaY to
      // each channel so the slider still has a visible effect on
      // a black frame.
      final lifted = (yNew).clamp(0.0, 1.0);
      return [lifted, lifted, lifted];
    }
    final ratio = yNew / y;
    return [
      (r * ratio).clamp(0.0, 1.0),
      (g * ratio).clamp(0.0, 1.0),
      (b * ratio).clamp(0.0, 1.0),
    ];
  }

  /// GLSL `smoothstep` mirror — Hermite interpolation between [edge0]
  /// and [edge1]. Returns 0 below [edge0], 1 above [edge1].
  static double _smoothstep(double edge0, double edge1, double x) {
    final t = ((x - edge0) / (edge1 - edge0)).clamp(0.0, 1.0);
    return t * t * (3.0 - 2.0 * t);
  }

  /// Hue of an RGB triple in `[0, 360)` degrees, or `null` for
  /// achromatic colours (R == G == B). Used by the chroma-preservation
  /// regression test in `highlights_shadows_chroma_test.dart`.
  static double? hue(double r, double g, double b) {
    final maxC = math.max(r, math.max(g, b));
    final minC = math.min(r, math.min(g, b));
    final delta = maxC - minC;
    if (delta < 1e-6) return null;
    double h;
    if (maxC == r) {
      h = ((g - b) / delta) % 6;
    } else if (maxC == g) {
      h = ((b - r) / delta) + 2;
    } else {
      h = ((r - g) / delta) + 4;
    }
    h *= 60;
    if (h < 0) h += 360;
    return h;
  }
}
