import 'dart:typed_data';

/// Phase XVI.15 → XVI.20 — global edge-refine for compose-on-bg
/// subject rasters. Operates on a straight-alpha RGBA buffer:
///
///   1. **Zero contaminated RGB** — every pixel with `α == 0` has
///      its RGB forced to zero. Those pixels carry whatever bg
///      colour the ORIGINAL photo had and if we leave it in, the
///      feather step below (or Flutter's own bilinear filter at
///      render time) will resurrect it as a halo.
///
///   2. **Feather** (when `featherPx > 0`) — runs an internal
///      decontaminate pass first (premul-blur radius=2 on 0<α<240
///      pixels) so the native RVM transition band is colour-clean
///      before the feather widens it. Then produces a
///      premul-blurred copy of the whole buffer and adopts its
///      values **only** on pixels with original α < 255 (XVI.19's
///      interior-preserving composite — keeps the subject crisp
///      while the ring gains its feather).
///
///      The decontam pass used to be a separate user-facing slider
///      (XVI.15–XVI.19). XVI.20 dropped it: RVM's near-binary matte
///      keeps fewer than 0.5 % of pixels in the 0<α<240 band, so
///      the slider was visually indistinguishable from a no-op. The
///      cleanup still runs silently whenever feather > 0 because
///      the math IS correct on contaminated mattes — it just doesn't
///      need a knob.
///
///   3. **Final premultiply** — always applied so the XVI.12 halo
///      safety net (premul-RGB declared as straight-α → Flutter
///      re-premuls → α² fringe falloff) stays in effect when
///      feather is zero.
///
/// At `featherPx == 0` the pipeline collapses to "zero contam +
/// final premul" — i.e. the pre-XVI.15 default bake, bit-for-bit.
class ComposeEdgeRefine {
  ComposeEdgeRefine._();

  /// The "fully opaque" threshold the internal decontaminate pass
  /// uses. Pixels with α below this and α > 0 get their RGB
  /// replaced with the α-weighted neighbour average; pixels at or
  /// above stay untouched (clean interior).
  static const int kOpaqueAlpha = 240;

  /// Run the pipeline and return a fresh `Uint8List` — the input
  /// buffer is not mutated. [featherPx] is clamped to `[0, 12]` and
  /// rounded to an integer box-blur radius.
  static Uint8List apply({
    required Uint8List straightRgba,
    required int width,
    required int height,
    required double featherPx,
  }) {
    assert(straightRgba.length == width * height * 4);
    final out = Uint8List.fromList(straightRgba);
    final radius = featherPx.clamp(0.0, 12.0).round();

    // 1. Wipe contaminated RGB on α=0 pixels so neither feather nor
    //    Flutter's bilinear filter can drag the original photo's bg
    //    colour into the matte boundary. Cheap — one linear scan.
    _zeroRgbWhereTransparent(out);

    // 2. Feather + bundled internal decontaminate.
    if (radius > 0) {
      // 2a. Decontaminate (XVI.20: internal, always-on at "full"
      //     strength when feather > 0). Pulls the native RVM
      //     0<α<240 fringe toward interior with a narrow premul
      //     box blur. Skipped when feather == 0 because no fringe
      //     widening will happen, and zero-feather output should
      //     match the pre-XVI.15 bake exactly.
      _decontaminate(out, width, height);

      // 2b. Interior-preserving feather (XVI.19). Produce a
      //     premul-blurred COPY — which has correctly-inpainted
      //     RGB and a soft α ramp in the ring — then adopt those
      //     values ONLY for pixels whose original α was less than
      //     255. Interior pixels (origA == 255) keep their source
      //     RGB and full α so the subject stays crisp while the
      //     edge gains its feather.
      final blurred = Uint8List.fromList(out);
      _premultiplyInPlace(blurred);
      _boxBlurAllChannels(blurred, width, height, radius);
      _unpremultiplyInPlace(blurred);
      for (int i = 0; i < out.length; i += 4) {
        if (out[i + 3] == 255) continue; // preserve sharp interior
        out[i] = blurred[i];
        out[i + 1] = blurred[i + 1];
        out[i + 2] = blurred[i + 2];
        out[i + 3] = blurred[i + 3];
      }
    }

    // 3. XVI.12 final premultiply — always applied so the raw-
    //    RVM-fringe halo safety net from the pre-XVI.15 code path
    //    stays in effect when feather is zero. For refined output
    //    the extra multiply darkens the fringe a touch but the
    //    COLOUR stays interior, which is the only thing that can
    //    visibly regress from this step.
    _premultiplyInPlace(out);

    return out;
  }

  /// Preprocess — zero RGB on every fully-transparent pixel so
  /// contamination can't survive into the feather or the Flutter
  /// bilinear stage.
  static void _zeroRgbWhereTransparent(Uint8List rgba) {
    for (int i = 0; i < rgba.length; i += 4) {
      if (rgba[i + 3] == 0) {
        rgba[i] = 0;
        rgba[i + 1] = 0;
        rgba[i + 2] = 0;
      }
    }
  }

  /// In-place premultiply: `rgb_new = rgb * α / 255`. Pixels with
  /// α=255 are unchanged; α=0 pixels already have RGB=0 from
  /// [_zeroRgbWhereTransparent] so they stay at 0.
  static void _premultiplyInPlace(Uint8List rgba) {
    for (int i = 0; i < rgba.length; i += 4) {
      final a = rgba[i + 3];
      if (a == 0 || a == 255) continue;
      rgba[i] = (rgba[i] * a) ~/ 255;
      rgba[i + 1] = (rgba[i + 1] * a) ~/ 255;
      rgba[i + 2] = (rgba[i + 2] * a) ~/ 255;
    }
  }

  /// In-place un-premultiply: `rgb_new = rgb × 255 / α`. Pixels
  /// with α=0 stay at RGB=0 (can't divide by zero — and the
  /// rendered result is transparent regardless). α=255 pixels are
  /// unchanged.
  static void _unpremultiplyInPlace(Uint8List rgba) {
    for (int i = 0; i < rgba.length; i += 4) {
      final a = rgba[i + 3];
      if (a == 0 || a == 255) continue;
      rgba[i] = ((rgba[i] * 255) ~/ a).clamp(0, 255);
      rgba[i + 1] = ((rgba[i + 1] * 255) ~/ a).clamp(0, 255);
      rgba[i + 2] = ((rgba[i + 2] * 255) ~/ a).clamp(0, 255);
    }
  }

  /// Decontaminate — pulls fringe RGB toward interior by blending
  /// each 0<α<kOpaqueAlpha pixel with an α-weighted neighbourhood
  /// average. Uses the same premul-blur trick as the feather pass
  /// (narrow radius = 2), which gives mathematically correct
  /// inpainting regardless of fringe width. RGB is replaced
  /// outright; α is not touched.
  ///
  /// Phase XVI.20: no longer takes a strength parameter — runs at
  /// strength=1.0 whenever feather > 0. The slider was dropped
  /// because RVM's near-binary matte keeps the visible surface
  /// area too small for the user to perceive a difference.
  static void _decontaminate(Uint8List rgba, int width, int height) {
    final target = Uint8List.fromList(rgba);
    _premultiplyInPlace(target);
    _boxBlurAllChannels(target, width, height, _kDecontamRadius);
    _unpremultiplyInPlace(target);
    for (int i = 0; i < rgba.length; i += 4) {
      final a = rgba[i + 3];
      if (a == 0 || a >= kOpaqueAlpha) continue;
      rgba[i] = target[i];
      rgba[i + 1] = target[i + 1];
      rgba[i + 2] = target[i + 2];
      // α deliberately untouched — decontam is a colour op.
    }
  }

  /// Radius for the pre-feather decontam blur. 2 px = 5×5 kernel is
  /// enough to average across RVM's native 2–4 px transition band.
  /// Larger radii over-soften the colour on thin subject features
  /// (hair, jewellery); smaller misses the outer fringe.
  static const int _kDecontamRadius = 2;

  /// Separable box blur over ALL FOUR channels via prefix sums —
  /// the premultiplied blur that gives mathematically correct
  /// alpha-aware averaging. Kernel size `2·radius + 1`; border
  /// pixels blur with the clamped count so edges don't leak zeros.
  ///
  /// Runs twice (horizontal then vertical), cost `O(w·h)` regardless
  /// of [radius]. Temporary buffer is `Int32List(max(w, h) + 1) × 4`
  /// per pass (one prefix per channel).
  static void _boxBlurAllChannels(
    Uint8List rgba,
    int width,
    int height,
    int radius,
  ) {
    final tmp = Uint8List(width * height * 4);
    _blurHorizontal(rgba, tmp, width, height, radius);
    _blurVertical(tmp, rgba, width, height, radius);
  }

  static void _blurHorizontal(
    Uint8List src,
    Uint8List dst,
    int width,
    int height,
    int radius,
  ) {
    final prefR = Int32List(width + 1);
    final prefG = Int32List(width + 1);
    final prefB = Int32List(width + 1);
    final prefA = Int32List(width + 1);
    for (int y = 0; y < height; y++) {
      final row = y * width;
      prefR[0] = 0;
      prefG[0] = 0;
      prefB[0] = 0;
      prefA[0] = 0;
      for (int x = 0; x < width; x++) {
        final i = (row + x) * 4;
        prefR[x + 1] = prefR[x] + src[i];
        prefG[x + 1] = prefG[x] + src[i + 1];
        prefB[x + 1] = prefB[x] + src[i + 2];
        prefA[x + 1] = prefA[x] + src[i + 3];
      }
      for (int x = 0; x < width; x++) {
        final start = (x - radius).clamp(0, width);
        final end = (x + radius + 1).clamp(0, width);
        final count = end - start;
        final i = (row + x) * 4;
        if (count == 0) {
          dst[i] = 0;
          dst[i + 1] = 0;
          dst[i + 2] = 0;
          dst[i + 3] = 0;
          continue;
        }
        dst[i] = (prefR[end] - prefR[start]) ~/ count;
        dst[i + 1] = (prefG[end] - prefG[start]) ~/ count;
        dst[i + 2] = (prefB[end] - prefB[start]) ~/ count;
        dst[i + 3] = (prefA[end] - prefA[start]) ~/ count;
      }
    }
  }

  static void _blurVertical(
    Uint8List src,
    Uint8List dst,
    int width,
    int height,
    int radius,
  ) {
    final prefR = Int32List(height + 1);
    final prefG = Int32List(height + 1);
    final prefB = Int32List(height + 1);
    final prefA = Int32List(height + 1);
    for (int x = 0; x < width; x++) {
      prefR[0] = 0;
      prefG[0] = 0;
      prefB[0] = 0;
      prefA[0] = 0;
      for (int y = 0; y < height; y++) {
        final i = (y * width + x) * 4;
        prefR[y + 1] = prefR[y] + src[i];
        prefG[y + 1] = prefG[y] + src[i + 1];
        prefB[y + 1] = prefB[y] + src[i + 2];
        prefA[y + 1] = prefA[y] + src[i + 3];
      }
      for (int y = 0; y < height; y++) {
        final start = (y - radius).clamp(0, height);
        final end = (y + radius + 1).clamp(0, height);
        final count = end - start;
        final i = (y * width + x) * 4;
        if (count == 0) {
          dst[i] = 0;
          dst[i + 1] = 0;
          dst[i + 2] = 0;
          dst[i + 3] = 0;
          continue;
        }
        dst[i] = (prefR[end] - prefR[start]) ~/ count;
        dst[i + 1] = (prefG[end] - prefG[start]) ~/ count;
        dst[i + 2] = (prefB[end] - prefB[start]) ~/ count;
        dst[i + 3] = (prefA[end] - prefA[start]) ~/ count;
      }
    }
  }
}
