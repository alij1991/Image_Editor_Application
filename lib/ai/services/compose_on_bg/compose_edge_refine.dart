import 'dart:typed_data';

/// Phase XVI.15 → XVI.18 — global edge-refine for compose-on-bg
/// subject rasters. Three operations on a straight-alpha RGBA
/// buffer, applied in this order:
///
///   1. **Zero contaminated RGB** — every pixel with `α == 0` has
///      its RGB forced to zero. Those pixels carry whatever bg
///      colour the ORIGINAL photo had and if we leave it in, the
///      feather step below (or Flutter's own bilinear filter at
///      render time) will resurrect it as a halo.
///
///   2. **Decontaminate** (optional, narrow window) — for every
///      pixel with `0 < α < kOpaqueAlpha`, pull RGB toward α=255
///      neighbours in a ±2 px window. This cleans the RVM matte's
///      NATIVE transition band (typically 2–4 px from bilinear mask
///      upsampling). Slider controls strength; no-op at 0.
///
///   3. **Premultiplied feather** — the centrepiece of XVI.18. A
///      plain α-channel blur combined with my old
///      "zero-RGB + look-for-clean-neighbours" decontam broke for
///      `featherPx > 2` because the ring's nearest clean pixel
///      sat outside a 5×5 sample window. The mathematically correct
///      fix is to blur **premultiplied** RGBA: scale RGB by α, box-
///      blur all four channels together, then un-premultiply. Blurring
///      premul RGBA is equivalent to an α-weighted average of straight
///      RGB, which means a pixel on the new fringe inherits interior
///      subject colour regardless of window size or ring width.
///
///      Concretely: near the boundary between α=0 (RGB=0 after step 1)
///      and α=255 (RGB=subj), the blurred premul RGB lands at
///      `subj × (interior_kernel_fraction)`, and the blurred α at
///      `255 × (interior_kernel_fraction)`. Dividing RGB by α/255 gives
///      `RGB=subj` exactly, for any kernel composition. The feathered
///      ring is always pure subject colour with a smooth α ramp.
///
/// After the three steps the buffer is **straight-alpha** RGBA with
/// clean fringe RGB. Flutter's bilinear filter at render time treats
/// it correctly — α=0 pixels have RGB=0, so no contamination can
/// bleed across the matte boundary via averaging.
///
/// Both feather and decontam are no-ops at their default (0)
/// strength, so fresh compose output renders unchanged until the
/// user opens the Edge Refine panel.
class ComposeEdgeRefine {
  ComposeEdgeRefine._();

  /// The "fully opaque" threshold that [_decontaminate] samples as
  /// clean foreground. Pixels at α ≥ this contribute to the
  /// interior colour average; pixels below it are candidates for
  /// contamination fix-up. Only matters for the narrow native-
  /// fringe decontam pass (step 2) — the premul feather (step 3)
  /// doesn't use it.
  static const int kOpaqueAlpha = 240;

  /// Run the three-step pipeline and return a fresh `Uint8List` —
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

    // 1. Wipe contaminated RGB on α=0 pixels so neither feather nor
    //    Flutter's bilinear filter can drag the original photo's bg
    //    colour into the matte boundary. Cheap — one linear scan.
    _zeroRgbWhereTransparent(out);

    // 2. Pull RVM's native 0<α<240 fringe toward interior. Narrow
    //    window is fine here because RVM's pre-feather transition
    //    is only a couple of pixels wide.
    if (strength > 0) {
      _decontaminate(out, width, height, strength);
    }

    // 3. Feather (XVI.19 — interior-preserving).
    //
    //    The previous revision blurred the whole buffer directly,
    //    which visibly smeared interior pixels (hair, face, clothes
    //    all mixed together on radius ≥ 3). Fix: produce a
    //    premul-blurred COPY — which has correctly-inpainted RGB
    //    and a soft α ramp in the ring — then adopt those values
    //    ONLY for pixels whose original α was less than 255. Interior
    //    pixels (origA == 255) keep their source RGB and full α,
    //    so the subject stays crisp while the edge gains its feather.
    if (radius > 0) {
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

    // 4. XVI.12 final premultiply — always applied so the raw-
    //    RVM-fringe halo safety net from the pre-XVI.15 code path
    //    stays in effect when decontam and feather are both zero.
    //    For refined output the extra multiply darkens the fringe
    //    a touch but the COLOUR stays interior, which is the only
    //    thing that can visibly regress from this step.
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
  /// average. Implementation uses the same premul-blur trick as the
  /// feather pass (narrow radius = 2), which gives mathematically
  /// correct inpainting regardless of fringe width — the prior
  /// per-pixel window scan silently no-opped whenever the nearest
  /// α≥240 neighbour sat outside its 5×5 sample box. [strength]
  /// blends between the original buffer (0) and the fully
  /// decontaminated one (1); α is not touched here, only RGB.
  static void _decontaminate(
    Uint8List rgba,
    int width,
    int height,
    double strength,
  ) {
    // Build an α-weighted RGB target via premul blur of a copy.
    final target = Uint8List.fromList(rgba);
    _premultiplyInPlace(target);
    _boxBlurAllChannels(target, width, height, _kDecontamRadius);
    _unpremultiplyInPlace(target);
    // Blend rgba ← target by strength on 0<α<kOpaqueAlpha pixels
    // only. α=0 pixels were handled by zero-transparent; α=255
    // pixels are clean interior and must not be softened.
    for (int i = 0; i < rgba.length; i += 4) {
      final a = rgba[i + 3];
      if (a == 0 || a >= kOpaqueAlpha) continue;
      rgba[i] =
          (rgba[i] + (target[i] - rgba[i]) * strength).round().clamp(0, 255);
      rgba[i + 1] = (rgba[i + 1] + (target[i + 1] - rgba[i + 1]) * strength)
          .round()
          .clamp(0, 255);
      rgba[i + 2] = (rgba[i + 2] + (target[i + 2] - rgba[i + 2]) * strength)
          .round()
          .clamp(0, 255);
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
