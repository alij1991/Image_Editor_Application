import 'dart:math' as math;
import 'dart:typed_data';

/// Phase XVI.15 — global edge-refine for compose-on-bg subject
/// rasters. Four operations on a straight-alpha RGBA buffer, run in
/// this order:
///
///   1. **Zero contaminated RGB** — every pixel with `α == 0` has
///      its RGB forced to zero. Those pixels carry whatever bg
///      colour the ORIGINAL photo had; if we leave them intact, the
///      feather step below will blur partial-α values onto them and
///      premultiply will scale their old RGB by the new α,
///      resurrecting the halo we're trying to kill. Zeroing first
///      makes them safe ground for feather to spread into.
///
///   2. **Alpha feather (XVI.16 re-ordered)** — separable box blur
///      of radius `featherPx` applied to the α channel only. Widens
///      the matte's hard edge into a soft gradient. Pixels that
///      were α=0 (and now zero RGB) become `0 < α < 255`.
///
///   3. **Decontaminate** — for every semi-transparent pixel
///      (0 < α < kOpaqueAlpha), pull RGB toward the average of its
///      fully-opaque neighbours, weighted by `(1 - α/kOpaqueAlpha) *
///      strength`. Running AFTER feather means the whole new
///      feathered ring gets colour-matched to the interior subject
///      — without this step, the ring stays RGB=0 (black) and
///      premul-scales to a dark halo.
///
///   4. **Premultiply** — final step for Flutter bilinear safety
///      (XVI.12 halo fix). RGB is multiplied by α so the downstream
///      filter can't pull bright contamination out of the α=0 band.
///
/// Both feather and decontam are no-ops at their default (zero)
/// strength, so fresh compose output renders unchanged until the
/// user opens the Edge Refine panel. A non-zero slider ALWAYS
/// produces a visible change — if it doesn't, that's a bug (the
/// XVI.16 re-ordering was motivated by exactly that report).
class ComposeEdgeRefine {
  ComposeEdgeRefine._();

  /// The "fully opaque" threshold that [decontaminate] samples as
  /// clean foreground. Pixels at α ≥ this contribute to the
  /// interior colour average; pixels below it are candidates for
  /// contamination fix-up.
  static const int kOpaqueAlpha = 240;

  /// When feather widens α into a previously-α=0 zone whose RGB was
  /// just zeroed (step 1 of [apply]), the naive premultiply gives
  /// a dark halo — `0 × α = 0`, which Flutter renders as a
  /// transparent-black ring fading to the new bg. To avoid that,
  /// [apply] guarantees at least this much decontam strength runs
  /// after feather so the new ring inherits interior FG colour.
  /// Below this floor the black-halo artefact is visible on
  /// coloured backgrounds; at or above, the fringe blends smoothly.
  static const double kFeatherDecontamFloor = 0.75;

  /// Run the four-step pipeline and return a fresh `Uint8List` —
  /// the input buffer is not mutated.
  ///
  /// [featherPx] is clamped to `[0, 12]` and rounded to an integer
  /// box-blur radius. [decontamStrength] is clamped to `[0, 1]`.
  static Uint8List apply({
    required Uint8List straightRgba,
    required int width,
    required int height,
    required double featherPx,
    required double decontamStrength,
  }) {
    assert(straightRgba.length == width * height * 4);
    final out = Uint8List.fromList(straightRgba);
    final strength = decontamStrength.clamp(0.0, 1.0);
    final radius = featherPx.clamp(0.0, 12.0).round();

    // 1. Wipe contaminated RGB on α=0 pixels so feather can spread
    //    into them without dragging the original-photo bg colour
    //    along. Cheap — one linear scan.
    _zeroRgbWhereTransparent(out);

    // 2. Soften the matte's hard edge. Does nothing at radius=0.
    if (radius > 0) {
      _boxBlurAlpha(out, width, height, radius);
    }

    // 3. Pull the new semi-transparent ring toward interior FG
    //    colour. When feather is active we force at least
    //    [kFeatherDecontamFloor] strength even if the user slider
    //    is lower — otherwise the freshly-zeroed ring renders as a
    //    transparent-black halo that's worse than the original
    //    contaminated edge (see the XVI.15 → XVI.17 bug report). At
    //    radius=0 the floor doesn't apply and decontam obeys the
    //    user slider as-is.
    final effStrength =
        radius > 0 ? math.max(strength, kFeatherDecontamFloor) : strength;
    if (effStrength > 0) {
      _decontaminate(out, width, height, effStrength);
    }

    // 4. Flutter-bilinear-safe premultiply (XVI.12).
    _premultiply(out);
    return out;
  }

  /// Preprocess — zero RGB on every fully-transparent pixel so the
  /// feather step can widen α into that region without bringing
  /// contaminated RGB along for the ride.
  static void _zeroRgbWhereTransparent(Uint8List rgba) {
    for (int i = 0; i < rgba.length; i += 4) {
      if (rgba[i + 3] == 0) {
        rgba[i] = 0;
        rgba[i + 1] = 0;
        rgba[i + 2] = 0;
      }
    }
  }

  /// In-place RGB adjustment for semi-transparent edge pixels,
  /// rewritten in XVI.17 so it still works AFTER a feather pass.
  ///
  /// For every pixel with `0 < α < kOpaqueAlpha` we look inside a
  /// 5×5 window for neighbours with **clean RGB** — a neighbour
  /// qualifies when `α > 0` AND its RGB sum exceeds [_kCleanRgbSum]
  /// (cheap proxy for "this pixel carries foreground colour"
  /// instead of "this pixel was zeroed by the pre-feather
  /// sanitise pass"). We average those clean neighbours and blend
  /// the centre pixel toward them by
  ///
  ///     t = strength × (pixel's own RGB was wiped ? 1 : 1 − α/kOpaqueAlpha)
  ///
  /// The branch on "RGB was wiped" is what makes feather + decontam
  /// look right: wiped pixels (the new feathered ring) get fully
  /// in-painted to the interior colour; genuinely semi-transparent
  /// pixels (hair wisps etc.) only get a gentle nudge so their
  /// natural FG colour survives.
  ///
  /// The pre-XVI.17 version required `α ≥ kOpaqueAlpha` neighbours;
  /// after a strong feather NO pixel is above that threshold and
  /// the decontam silently became a no-op, which is what the user's
  /// "the sliders do nothing" bug report showed.
  static void _decontaminate(
    Uint8List rgba,
    int width,
    int height,
    double strength,
  ) {
    const window = 2; // ± 2 px → 5×5 sample.
    // Snapshot so we sample the pre-pass state, not a half-updated
    // buffer. Cheap — only done once per apply call.
    final source = Uint8List.fromList(rgba);
    for (int y = 0; y < height; y++) {
      for (int x = 0; x < width; x++) {
        final idx = (y * width + x) * 4;
        final a = source[idx + 3];
        if (a == 0 || a >= kOpaqueAlpha) continue;
        final ownR = source[idx];
        final ownG = source[idx + 1];
        final ownB = source[idx + 2];
        final wiped = ownR + ownG + ownB <= _kCleanRgbSum;
        int sumR = 0, sumG = 0, sumB = 0, n = 0;
        final y0 = (y - window).clamp(0, height - 1);
        final y1 = (y + window).clamp(0, height - 1);
        final x0 = (x - window).clamp(0, width - 1);
        final x1 = (x + window).clamp(0, width - 1);
        for (int ny = y0; ny <= y1; ny++) {
          final row = ny * width;
          for (int nx = x0; nx <= x1; nx++) {
            // Exclude self — we're trying to pull THIS pixel
            // toward its neighbours, and including self in the
            // average dilutes the pull toward whatever the fringe
            // already is. Subtle but critical for the "green edge
            // between red opaque pixels" canonical test.
            if (ny == y && nx == x) continue;
            final nIdx = (row + nx) * 4;
            final na = source[nIdx + 3];
            if (na == 0) continue;
            final nR = source[nIdx];
            final nG = source[nIdx + 1];
            final nB = source[nIdx + 2];
            if (nR + nG + nB <= _kCleanRgbSum) continue;
            sumR += nR;
            sumG += nG;
            sumB += nB;
            n++;
          }
        }
        if (n == 0) continue;
        final avgR = sumR ~/ n;
        final avgG = sumG ~/ n;
        final avgB = sumB ~/ n;
        final t = wiped ? strength : strength * (1.0 - a / kOpaqueAlpha);
        rgba[idx] =
            (rgba[idx] + (avgR - rgba[idx]) * t).round().clamp(0, 255);
        rgba[idx + 1] =
            (rgba[idx + 1] + (avgG - rgba[idx + 1]) * t).round().clamp(0, 255);
        rgba[idx + 2] =
            (rgba[idx + 2] + (avgB - rgba[idx + 2]) * t).round().clamp(0, 255);
      }
    }
  }

  /// A pixel's RGB sum ≤ this is treated as "no colour signal" —
  /// i.e. either the zero-transparent preprocess wiped it or the
  /// source was near-black. Used by [_decontaminate] to gate
  /// sample neighbours and to detect "fully in-paint" target
  /// pixels. 30 is just low enough to exclude near-black noise
  /// while still accepting genuinely dark foreground tones.
  static const int _kCleanRgbSum = 30;

  /// Separable box blur over the α channel only, via per-row /
  /// per-column prefix sums.
  ///
  /// Kernel size is `2·radius + 1`; range is clamped at the image
  /// edges so the effective count there is < kernel (pixels at the
  /// border blur with fewer samples rather than leaking zeros in).
  /// RGB channels are not touched.
  static void _boxBlurAlpha(
    Uint8List rgba,
    int width,
    int height,
    int radius,
  ) {
    final tmp = Uint8List(width * height);

    // Horizontal pass — rgba.α → tmp via row prefix sums.
    final rowPrefix = Int32List(width + 1);
    for (int y = 0; y < height; y++) {
      final row = y * width;
      rowPrefix[0] = 0;
      for (int x = 0; x < width; x++) {
        rowPrefix[x + 1] = rowPrefix[x] + rgba[(row + x) * 4 + 3];
      }
      for (int x = 0; x < width; x++) {
        final start = (x - radius).clamp(0, width);
        final end = (x + radius + 1).clamp(0, width);
        final count = end - start;
        tmp[row + x] =
            count == 0 ? 0 : ((rowPrefix[end] - rowPrefix[start]) ~/ count);
      }
    }

    // Vertical pass — tmp → rgba.α via column prefix sums.
    final colPrefix = Int32List(height + 1);
    for (int x = 0; x < width; x++) {
      colPrefix[0] = 0;
      for (int y = 0; y < height; y++) {
        colPrefix[y + 1] = colPrefix[y] + tmp[y * width + x];
      }
      for (int y = 0; y < height; y++) {
        final start = (y - radius).clamp(0, height);
        final end = (y + radius + 1).clamp(0, height);
        final count = end - start;
        final v =
            count == 0 ? 0 : ((colPrefix[end] - colPrefix[start]) ~/ count);
        rgba[(y * width + x) * 4 + 3] = v;
      }
    }
  }

  /// Premultiply RGB by α in-place. Matches the Phase XVI.12 halo
  /// fix — the encoder hands Flutter a premultiplied buffer so the
  /// bilinear filter can't pull bright contamination out of the
  /// α=0 band.
  static void _premultiply(Uint8List rgba) {
    for (int i = 0; i < rgba.length; i += 4) {
      final a = rgba[i + 3];
      if (a == 0) {
        rgba[i] = 0;
        rgba[i + 1] = 0;
        rgba[i + 2] = 0;
      } else if (a < 255) {
        rgba[i] = (rgba[i] * a) ~/ 255;
        rgba[i + 1] = (rgba[i + 1] * a) ~/ 255;
        rgba[i + 2] = (rgba[i + 2] * a) ~/ 255;
      }
    }
  }
}
