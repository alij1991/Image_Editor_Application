import 'dart:math' as math;

import 'package:image/image.dart' as img;

import '../domain/document_classifier.dart';

/// Compute an [ImageStats] snapshot from [src]. Downscales to ~256 px
/// long edge first so the colour-variance + sharpness scans stay
/// cheap on multi-megapixel inputs.
ImageStats computeImageStats(img.Image src) {
  const target = 256;
  final longEdge = math.max(src.width, src.height);
  final scale = longEdge > target ? target / longEdge : 1.0;
  final small = scale < 1.0
      ? img.copyResize(
          src,
          width: (src.width * scale).round(),
          height: (src.height * scale).round(),
          interpolation: img.Interpolation.linear,
        )
      : src;

  // Mean hue vector + variance — each pixel projected onto the
  // chroma plane (sin/cos of hue weighted by saturation*value).
  // Documents have low chroma magnitude; photos have high. Using the
  // length of the mean chroma vector + the per-pixel variance gives
  // a number that's stable against grey backgrounds without needing
  // a real HSV conversion.
  var sumChromaSqr = 0.0;
  final n = small.width * small.height;
  for (final px in small) {
    final r = px.r.toDouble();
    final g = px.g.toDouble();
    final b = px.b.toDouble();
    final maxC = math.max(r, math.max(g, b));
    final minC = math.min(r, math.min(g, b));
    final chroma = (maxC - minC) / 255.0;
    sumChromaSqr += chroma * chroma;
  }
  final richness = (math.sqrt(sumChromaSqr / n)).clamp(0.0, 1.0);
  final sharpness = computeSharpness(small);
  return ImageStats(
    width: src.width,
    height: src.height,
    colorRichness: richness,
    sharpness: sharpness,
  );
}

/// VIII.11 — Laplacian-variance sharpness, normalised to [0..1].
///
/// Computes the discrete Laplacian (centre × 4 minus 4 neighbours) on
/// the grayscale of [src], then takes the variance of those responses
/// divided by a heuristic upper bound (250) to land in [0..1]. Sharp
/// document scans produce variance ≈ 800-1500 (clamped to 1.0); motion
/// blurred or out-of-focus inputs produce variance ≈ 30-100 (≈ 0.1-0.4).
///
/// Public so the test suite can drive it on synthetic blurry vs sharp
/// fixtures without going through [computeImageStats].
double computeSharpness(img.Image src) {
  final w = src.width;
  final h = src.height;
  if (w < 3 || h < 3) return 1.0;
  // Pre-extract grayscale into a flat byte buffer so the Laplacian
  // loop is one indexed lookup per neighbour.
  final gray = List<double>.filled(w * h, 0);
  var i = 0;
  for (final px in src) {
    final r = px.r.toDouble();
    final g = px.g.toDouble();
    final b = px.b.toDouble();
    gray[i] = 0.299 * r + 0.587 * g + 0.114 * b;
    i++;
  }
  var sum = 0.0;
  var sumSq = 0.0;
  var count = 0;
  for (var y = 1; y < h - 1; y++) {
    for (var x = 1; x < w - 1; x++) {
      final idx = y * w + x;
      final centre = gray[idx];
      final lap = 4 * centre -
          gray[idx - 1] -
          gray[idx + 1] -
          gray[idx - w] -
          gray[idx + w];
      sum += lap;
      sumSq += lap * lap;
      count++;
    }
  }
  if (count == 0) return 1.0;
  final mean = sum / count;
  final variance = (sumSq / count) - mean * mean;
  // Empirical normalisation: variance > 250 ≈ "indistinguishably
  // sharp" on a 256-px grayscale. Clamp to [0, 1].
  return (variance / 250.0).clamp(0.0, 1.0);
}
