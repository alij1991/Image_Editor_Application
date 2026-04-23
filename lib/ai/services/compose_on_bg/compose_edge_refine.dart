import 'dart:typed_data';

/// Phase XVI.15 — global edge-refine for compose-on-bg subject
/// rasters. Two operations that run sequentially on a straight-alpha
/// RGBA buffer, in this order:
///
///   1. **Decontaminate** — for every semi-transparent edge pixel
///      (0 < α < 255), pull its RGB toward the average of its
///      nearest *fully-opaque* neighbours, weighted by how
///      transparent the pixel is. This is the mitigation for the
///      "original-photo bg colour is still baked into RGB where
///      α < 255" problem that gives compose its "pasted sticker"
///      fringe on coloured backgrounds. `strength` in `0..1`.
///
///   2. **Alpha feather** — separable box blur of radius
///      `featherPx` applied to the α channel only. The alpha
///      matte's hard edge turns into a soft gradient so the
///      subject fades into the new bg instead of cutting sharply.
///      RGB is untouched by this step — the decontaminate already
///      cleaned up the colour; we're only softening α.
///
/// After both, RGB is premultiplied by α (matches the XVI.12 halo
/// fix) so Flutter's bilinear filter can't resurrect black from the
/// α=0 pixels into the edge band when the subject is drawn at a
/// non-integer scale.
///
/// Both operations are no-ops at their default (zero) strength, so
/// fresh compose output renders unchanged until the user opens the
/// Edge Refine panel.
class ComposeEdgeRefine {
  ComposeEdgeRefine._();

  /// The "fully opaque" threshold that [decontaminate] samples as
  /// clean foreground. Pixels at α ≥ this contribute to the
  /// interior colour average; pixels below it are candidates for
  /// contamination fix-up.
  static const int kOpaqueAlpha = 240;

  /// Run decontaminate + feather + premultiply and return a fresh
  /// `Uint8List` — the input buffer is not mutated.
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

    if (strength > 0) {
      _decontaminate(out, width, height, strength);
    }
    if (radius > 0) {
      _boxBlurAlpha(out, width, height, radius);
    }
    _premultiply(out);
    return out;
  }

  /// In-place RGB adjustment for semi-transparent edge pixels.
  ///
  /// For each pixel with `0 < α < kOpaqueAlpha`, we compute the
  /// average RGB of fully-opaque neighbours inside a 5×5 window and
  /// blend toward that average by
  ///
  ///     t = strength × (1 − α / kOpaqueAlpha)
  ///
  /// so α=0 pixels get fully replaced (they had no foreground info
  /// anyway) and near-opaque pixels are barely touched. Pixels with
  /// no opaque neighbour in range are left alone — we'd rather keep
  /// a slightly wrong colour than replace it with black from a
  /// miss.
  ///
  /// This approximates edge-decontam in the matting literature
  /// (Levin et al closed-form matting, etc.) without the cost of a
  /// global solve. The 5×5 window is enough for the fringe band
  /// typical of a 1080×1920 subject; larger windows blur interior
  /// edges into each other.
  static void _decontaminate(
    Uint8List rgba,
    int width,
    int height,
    double strength,
  ) {
    const window = 2; // ± 2 px → 5×5 sample.
    for (int y = 0; y < height; y++) {
      for (int x = 0; x < width; x++) {
        final idx = (y * width + x) * 4;
        final a = rgba[idx + 3];
        if (a == 0 || a >= kOpaqueAlpha) continue;
        int sumR = 0, sumG = 0, sumB = 0, n = 0;
        final y0 = (y - window).clamp(0, height - 1);
        final y1 = (y + window).clamp(0, height - 1);
        final x0 = (x - window).clamp(0, width - 1);
        final x1 = (x + window).clamp(0, width - 1);
        for (int ny = y0; ny <= y1; ny++) {
          final row = ny * width;
          for (int nx = x0; nx <= x1; nx++) {
            final nIdx = (row + nx) * 4;
            if (rgba[nIdx + 3] >= kOpaqueAlpha) {
              sumR += rgba[nIdx];
              sumG += rgba[nIdx + 1];
              sumB += rgba[nIdx + 2];
              n++;
            }
          }
        }
        if (n == 0) continue;
        final avgR = sumR ~/ n;
        final avgG = sumG ~/ n;
        final avgB = sumB ~/ n;
        final t = strength * (1.0 - a / kOpaqueAlpha);
        rgba[idx] = (rgba[idx] + (avgR - rgba[idx]) * t).round().clamp(0, 255);
        rgba[idx + 1] =
            (rgba[idx + 1] + (avgG - rgba[idx + 1]) * t).round().clamp(0, 255);
        rgba[idx + 2] =
            (rgba[idx + 2] + (avgB - rgba[idx + 2]) * t).round().clamp(0, 255);
      }
    }
  }

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
