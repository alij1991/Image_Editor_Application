import 'dart:math' as math;
import 'dart:typed_data';

/// Pure-Dart mirror of the math in `shaders/dehaze.frag` (XVI.30).
///
/// The shader implements a single-pass approximation of the dark
/// channel prior (He, Sun, Tang — 2009). Both shader and helper share:
///
///   1. **Local dark channel** — `min` over R,G,B and a ±radius patch.
///   2. **Atmospheric light A** — brightest of 5 widely-spaced
///      samples (4 edge centres + image centre), floored away from
///      black.
///   3. **Transmission** — `t = 1 - omega * darkChannel / mean(A)`,
///      clamped to `[t0, 1]`.
///   4. **Recovery** — `J = (I - A) / t + A`, then `mix(I, J, amount)`
///      for positive slider, `mix(I, A, |amount|)` for negative.
///
/// Identity preserved at `amount = 0` (reproduces the input pixel
/// exactly). The Dart helper sticks to the same constants
/// ([kOmega], [kTransMin], [kABlackFloor]) so a Dart test can pin the
/// algorithm without standing up a real GPU fixture.
class DehazeMath {
  DehazeMath._();

  /// Residual-haze retention. Pulling the slider to 1.0 still keeps
  /// 5% of the haze rather than fully stripping it — matches the
  /// He paper's recommendation and avoids the "underwater" look
  /// you get with omega = 1.
  static const double kOmega = 0.95;

  /// Transmission floor. Pixels in heavy haze with near-zero
  /// transmission would otherwise blow up under the `(I - A) / t + A`
  /// recovery; clamping at 0.10 keeps recovered values plausible.
  static const double kTransMin = 0.10;

  /// Atmospheric-light black floor. A near-black corner sample (e.g.
  /// letterboxed input) would make the transmission division
  /// degenerate; floor each channel at 0.05.
  static const double kABlackFloor = 0.05;

  /// Identity threshold. `|amount| < this` short-circuits to the
  /// input pixel. Matches the shader's `1e-4` cutoff so the two
  /// implementations agree at the rounding edge.
  static const double kIdentityEpsilon = 1e-4;

  /// Compute the local dark channel at pixel `(cx, cy)` with a
  /// `±radius` square patch. `image` is row-major RGBA bytes
  /// (`width * height * 4`). The patch wraps via `clamp` to image
  /// bounds — the GPU does the same when the texture is sampled
  /// outside `[0, 1]`.
  static double darkChannel({
    required Uint8List image,
    required int width,
    required int height,
    required int cx,
    required int cy,
    int radius = 2,
  }) {
    var dc = 1.0;
    for (var dy = -radius; dy <= radius; dy++) {
      final y = (cy + dy).clamp(0, height - 1);
      for (var dx = -radius; dx <= radius; dx++) {
        final x = (cx + dx).clamp(0, width - 1);
        final i = (y * width + x) * 4;
        final r = image[i] / 255.0;
        final g = image[i + 1] / 255.0;
        final b = image[i + 2] / 255.0;
        final m = math.min(math.min(r, g), b);
        if (m < dc) dc = m;
      }
    }
    return dc;
  }

  /// Estimate atmospheric light A from a 5-point grid. Returns three
  /// `[0, 1]` channel values, each floored at [kABlackFloor].
  ///
  /// Grid points (image-relative): top centre `(0.5, 0.05)`, left
  /// centre `(0.05, 0.5)`, right centre `(0.95, 0.5)`, bottom
  /// centre `(0.5, 0.95)`, image centre `(0.5, 0.5)`. Picks the
  /// brightest (max R+G+B) and floors black-channels.
  static List<double> atmosphericLight({
    required Uint8List image,
    required int width,
    required int height,
  }) {
    List<double> sample(double u, double v) {
      final x = (u * (width - 1)).round().clamp(0, width - 1);
      final y = (v * (height - 1)).round().clamp(0, height - 1);
      final i = (y * width + x) * 4;
      return [
        image[i] / 255.0,
        image[i + 1] / 255.0,
        image[i + 2] / 255.0,
      ];
    }

    final samples = [
      sample(0.5, 0.05),
      sample(0.05, 0.5),
      sample(0.95, 0.5),
      sample(0.5, 0.95),
      sample(0.5, 0.5),
    ];
    var best = samples.first;
    var bestSum = best[0] + best[1] + best[2];
    for (var i = 1; i < samples.length; i++) {
      final s = samples[i];
      final ss = s[0] + s[1] + s[2];
      if (ss > bestSum) {
        best = s;
        bestSum = ss;
      }
    }
    return [
      math.max(best[0], kABlackFloor),
      math.max(best[1], kABlackFloor),
      math.max(best[2], kABlackFloor),
    ];
  }

  /// Apply DCP dehaze to a single pixel given the precomputed dark
  /// channel `dc` and atmospheric light `A`. Slider `amount` is in
  /// `[-1, 1]`. Output is clamped to `[0, 1]`.
  static List<double> applyPixel({
    required double r,
    required double g,
    required double b,
    required double dc,
    required List<double> a,
    double amount = 0,
  }) {
    if (amount.abs() < kIdentityEpsilon) {
      return [r.clamp(0.0, 1.0), g.clamp(0.0, 1.0), b.clamp(0.0, 1.0)];
    }
    final aAvg = (a[0] + a[1] + a[2]) / 3.0;
    final aAvgSafe = math.max(aAvg, kABlackFloor);
    var t = 1.0 - kOmega * (dc / aAvgSafe);
    if (t < kTransMin) t = kTransMin;
    if (t > 1.0) t = 1.0;

    final jr = (r - a[0]) / t + a[0];
    final jg = (g - a[1]) / t + a[1];
    final jb = (b - a[2]) / t + a[2];

    double or, og, ob;
    if (amount >= 0) {
      or = r + (jr - r) * amount;
      og = g + (jg - g) * amount;
      ob = b + (jb - b) * amount;
    } else {
      // Add haze: blend toward atmospheric light.
      final w = -amount;
      or = r + (a[0] - r) * w;
      og = g + (a[1] - g) * w;
      ob = b + (a[2] - b) * w;
    }
    return [
      or.clamp(0.0, 1.0),
      og.clamp(0.0, 1.0),
      ob.clamp(0.0, 1.0),
    ];
  }
}
