import 'dart:math' as math;
import 'dart:typed_data';

/// Phase XVI.2: edge-quality helpers for the compose-on-bg flow.
///
/// The raw matte from a bg-removal strategy ships with three real
/// artefacts that make a subject look cut-out-and-pasted rather than
/// truly recomposed:
///
///   1. A hard, stair-stepped alpha edge — the segmentation output
///      runs at 256–1024 px, and any crisp transition looks fake
///      when composited at full resolution.
///   2. Colour contamination on partial-alpha edges — fine hair /
///      fur strands pick up the original background's hue and carry
///      it over like a halo.
///   3. "Floating subject" syndrome — nothing anchors the subject
///      to the new scene, so the composite reads as a sticker.
///
/// The four helpers in this file address each in turn and compose
/// cleanly: [erodeAlpha] pulls the matte inward one pixel to drop
/// the contaminated outer rim; [featherAlpha] replaces the crisp
/// boundary with a short Gaussian ramp; [decontaminateEdges]
/// repaints partial-alpha RGB from the subject's interior so the
/// halo goes away; [stampContactShadow] adds a soft drop shadow
/// below the subject so it reads as sitting on the new bg instead
/// of floating in front of it.
///
/// All helpers operate on flat RGBA8 buffers in-place or via a
/// returned copy; none depend on `dart:ui` so they run in any
/// isolate the caller wants and are unit-testable without a
/// Flutter binding.
class ComposeEdgeOps {
  const ComposeEdgeOps._();

  /// Shrink the alpha channel by a 3×3 min filter, [iterations]
  /// times. Each iteration peels one pixel off the outer edge so a
  /// single pass is plenty for most strategies; RVM's edges are
  /// already tight.
  ///
  /// Alpha is modified in-place on the returned buffer (a copy of
  /// [rgba]); RGB is untouched.
  static Uint8List erodeAlpha({
    required Uint8List rgba,
    required int width,
    required int height,
    int iterations = 1,
  }) {
    _validate(rgba, width, height);
    if (iterations <= 0) return Uint8List.fromList(rgba);
    Uint8List current = Uint8List.fromList(rgba);
    for (int pass = 0; pass < iterations; pass++) {
      current = _erodeAlphaOnePass(current, width, height);
    }
    return current;
  }

  /// Feather the alpha channel with a separable 3-tap box blur,
  /// [passes] times. One pass is a 3 × 3 average; two passes give a
  /// rough Gaussian with σ ≈ 1 px. More passes → softer edge.
  ///
  /// RGB is copied through unchanged — this helper only softens the
  /// transition between opaque and transparent pixels.
  static Uint8List featherAlpha({
    required Uint8List rgba,
    required int width,
    required int height,
    int passes = 1,
  }) {
    _validate(rgba, width, height);
    if (passes <= 0) return Uint8List.fromList(rgba);
    Uint8List current = Uint8List.fromList(rgba);
    for (int pass = 0; pass < passes; pass++) {
      current = _blurAlphaHorizontal(current, width, height);
      current = _blurAlphaVertical(current, width, height);
    }
    return current;
  }

  /// Repaint the RGB of partial-alpha pixels from the subject's
  /// interior so the original-bg colour spill on hair / fur edges
  /// doesn't bleed into the new composite.
  ///
  /// Strategy: for every pixel where alpha ∈ (`lo`, `hi`), average
  /// the RGB of interior pixels (alpha ≥ `hi`) in a small
  /// neighbourhood. Blend the original RGB toward that interior
  /// average by `(1 - alpha) * strength`. Fully opaque + fully
  /// transparent pixels are untouched.
  ///
  /// This is the minimal practical "colour decontamination" — a
  /// full premultiplied-divide + interior-inpaint (Levin et al.)
  /// would give even better results on long fine hair but also
  /// needs a per-pixel nearest-interior search that's heavier than
  /// the return on mobile CPU.
  static Uint8List decontaminateEdges({
    required Uint8List rgba,
    required int width,
    required int height,
    int radius = 3,
    double strength = 0.75,
    double lo = 0.05,
    double hi = 0.95,
  }) {
    _validate(rgba, width, height);
    if (strength <= 0 || radius <= 0) return Uint8List.fromList(rgba);

    final out = Uint8List.fromList(rgba);
    final loByte = (lo * 255).round();
    final hiByte = (hi * 255).round();

    for (int y = 0; y < height; y++) {
      for (int x = 0; x < width; x++) {
        final i = (y * width + x) * 4;
        final a = rgba[i + 3];
        if (a <= loByte || a >= hiByte) continue;

        // Sample interior neighbourhood (alpha ≥ hi) within a
        // `(2*radius+1)²` window. Uses the SOURCE buffer so partial
        // edges don't contaminate each other inside this pass.
        int sumR = 0, sumG = 0, sumB = 0, count = 0;
        final x0 = math.max(0, x - radius);
        final x1 = math.min(width - 1, x + radius);
        final y0 = math.max(0, y - radius);
        final y1 = math.min(height - 1, y + radius);
        for (int yy = y0; yy <= y1; yy++) {
          for (int xx = x0; xx <= x1; xx++) {
            final j = (yy * width + xx) * 4;
            if (rgba[j + 3] < hiByte) continue;
            sumR += rgba[j];
            sumG += rgba[j + 1];
            sumB += rgba[j + 2];
            count++;
          }
        }
        if (count == 0) continue;
        final avgR = sumR / count;
        final avgG = sumG / count;
        final avgB = sumB / count;

        // Blend toward interior: weight grows as alpha shrinks (the
        // further out on the edge, the more decontamination helps).
        final alphaNorm = a / 255.0;
        final t = ((1.0 - alphaNorm) * strength).clamp(0.0, 1.0);
        final r = rgba[i] + (avgR - rgba[i]) * t;
        final g = rgba[i + 1] + (avgG - rgba[i + 1]) * t;
        final b = rgba[i + 2] + (avgB - rgba[i + 2]) * t;
        out[i] = r.round().clamp(0, 255);
        out[i + 1] = g.round().clamp(0, 255);
        out[i + 2] = b.round().clamp(0, 255);
      }
    }
    return out;
  }

  /// Paint a soft dark "contact shadow" into the subject RGBA below
  /// the subject's silhouette. The shadow is baked into the subject
  /// raster so that moving the subject via the layer transform
  /// moves its shadow with it — no separate shadow layer needed.
  ///
  /// The shadow is drawn as an elliptical radial falloff centred
  /// beneath the subject's foot, sized proportionally to the
  /// subject's axis-aligned bounding box. Pixels inside the shadow
  /// ellipse that have no subject alpha are filled with
  /// semi-transparent grey.
  ///
  /// - [opacity] scales the shadow's peak alpha (default 0.35 —
  ///   stronger shadows look fake against bright backgrounds).
  /// - [widthScale] controls the ellipse width relative to the
  ///   subject bbox (default 0.85 — a little narrower than the
  ///   subject for a cast shadow).
  /// - [heightScale] controls the ellipse height relative to bbox
  ///   width (default 0.16 — a flat oval feels grounded).
  static Uint8List stampContactShadow({
    required Uint8List rgba,
    required int width,
    required int height,
    double opacity = 0.35,
    double widthScale = 0.85,
    double heightScale = 0.16,
    double verticalGapScale = 0.02,
    int alphaThreshold = 32,
  }) {
    _validate(rgba, width, height);
    if (opacity <= 0) return Uint8List.fromList(rgba);

    // Find subject bbox from alpha ≥ threshold.
    int minX = width, minY = height, maxX = -1, maxY = -1;
    for (int y = 0; y < height; y++) {
      for (int x = 0; x < width; x++) {
        final i = (y * width + x) * 4;
        if (rgba[i + 3] >= alphaThreshold) {
          if (x < minX) minX = x;
          if (x > maxX) maxX = x;
          if (y < minY) minY = y;
          if (y > maxY) maxY = y;
        }
      }
    }
    if (maxX < 0) return Uint8List.fromList(rgba); // empty subject

    final subjectW = (maxX - minX + 1).toDouble();
    final cx = (minX + maxX) / 2.0;
    final gap = subjectW * verticalGapScale;
    final ellipseCy = maxY + gap;
    final ellipseRx = subjectW * 0.5 * widthScale;
    final ellipseRy = subjectW * heightScale;
    if (ellipseRx <= 0 || ellipseRy <= 0) return Uint8List.fromList(rgba);

    // Iterate over the ellipse's axis-aligned bbox and stamp the
    // soft-edged shadow. Skip pixels already within the subject's
    // alpha so we don't darken the subject itself.
    final out = Uint8List.fromList(rgba);
    final peakAlphaByte = (opacity * 255).round().clamp(0, 255);
    final y0 = (ellipseCy - ellipseRy).floor().clamp(0, height - 1);
    final y1 = (ellipseCy + ellipseRy).ceil().clamp(0, height - 1);
    final x0 = (cx - ellipseRx).floor().clamp(0, width - 1);
    final x1 = (cx + ellipseRx).ceil().clamp(0, width - 1);
    for (int y = y0; y <= y1; y++) {
      final dy = (y - ellipseCy) / ellipseRy;
      for (int x = x0; x <= x1; x++) {
        final dx = (x - cx) / ellipseRx;
        final d2 = dx * dx + dy * dy;
        if (d2 >= 1.0) continue;
        // Radial falloff — peak at centre, 0 at ellipse edge.
        final falloff = (1.0 - math.sqrt(d2));
        final shadowAlpha = (falloff * peakAlphaByte).round();
        if (shadowAlpha <= 0) continue;
        final i = (y * width + x) * 4;
        // Don't darken inside the subject.
        if (out[i + 3] >= alphaThreshold) continue;
        // Alpha-over: blend dark grey onto whatever's already there.
        // (Usually transparent, but if an earlier stamp ran we
        // preserve it via standard src-over.)
        const shadowColor = 24; // near-black
        final existingA = out[i + 3];
        final newA = existingA + shadowAlpha - (existingA * shadowAlpha) ~/ 255;
        if (newA == 0) continue;
        out[i] = _srcOver(out[i], existingA, shadowColor, shadowAlpha, newA);
        out[i + 1] =
            _srcOver(out[i + 1], existingA, shadowColor, shadowAlpha, newA);
        out[i + 2] =
            _srcOver(out[i + 2], existingA, shadowColor, shadowAlpha, newA);
        out[i + 3] = newA.clamp(0, 255);
      }
    }
    return out;
  }

  /// Standard alpha-over blend for a single channel.
  static int _srcOver(int dstC, int dstA, int srcC, int srcA, int outA) {
    // out = (src * srcA + dst * dstA * (1 - srcA/255)) / outA
    final inv = 255 - srcA;
    final num = srcC * srcA + dstC * dstA * inv ~/ 255;
    if (outA == 0) return 0;
    return (num ~/ outA).clamp(0, 255);
  }

  static Uint8List _erodeAlphaOnePass(
      Uint8List src, int w, int h) {
    final out = Uint8List.fromList(src);
    for (int y = 0; y < h; y++) {
      for (int x = 0; x < w; x++) {
        final i = (y * w + x) * 4;
        int minA = src[i + 3];
        final x0 = x > 0 ? x - 1 : 0;
        final x1 = x < w - 1 ? x + 1 : w - 1;
        final y0 = y > 0 ? y - 1 : 0;
        final y1 = y < h - 1 ? y + 1 : h - 1;
        for (int yy = y0; yy <= y1; yy++) {
          for (int xx = x0; xx <= x1; xx++) {
            final a = src[(yy * w + xx) * 4 + 3];
            if (a < minA) minA = a;
          }
        }
        out[i + 3] = minA;
      }
    }
    return out;
  }

  static Uint8List _blurAlphaHorizontal(
      Uint8List src, int w, int h) {
    final out = Uint8List.fromList(src);
    for (int y = 0; y < h; y++) {
      for (int x = 0; x < w; x++) {
        final i = (y * w + x) * 4;
        final a0 = x > 0 ? src[(y * w + x - 1) * 4 + 3] : src[i + 3];
        final a1 = src[i + 3];
        final a2 = x < w - 1 ? src[(y * w + x + 1) * 4 + 3] : src[i + 3];
        out[i + 3] = ((a0 + a1 + a2) ~/ 3).clamp(0, 255);
      }
    }
    return out;
  }

  static Uint8List _blurAlphaVertical(
      Uint8List src, int w, int h) {
    final out = Uint8List.fromList(src);
    for (int y = 0; y < h; y++) {
      for (int x = 0; x < w; x++) {
        final i = (y * w + x) * 4;
        final a0 = y > 0 ? src[((y - 1) * w + x) * 4 + 3] : src[i + 3];
        final a1 = src[i + 3];
        final a2 = y < h - 1 ? src[((y + 1) * w + x) * 4 + 3] : src[i + 3];
        out[i + 3] = ((a0 + a1 + a2) ~/ 3).clamp(0, 255);
      }
    }
    return out;
  }

  static void _validate(Uint8List rgba, int w, int h) {
    if (w <= 0 || h <= 0) {
      throw ArgumentError('width/height must be > 0');
    }
    if (rgba.length != w * h * 4) {
      throw ArgumentError('rgba length ${rgba.length} != ${w * h * 4}');
    }
  }
}
