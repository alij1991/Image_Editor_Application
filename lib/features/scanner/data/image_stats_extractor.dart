import 'dart:math' as math;

import 'package:image/image.dart' as img;

import '../domain/document_classifier.dart';

/// Compute an [ImageStats] snapshot from [src]. Downscales to ~256 px
/// long edge first so the colour-variance scan stays cheap on
/// multi-megapixel inputs.
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
  return ImageStats(
    width: src.width,
    height: src.height,
    colorRichness: richness,
  );
}
