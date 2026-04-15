import 'dart:io';
import 'dart:math' as math;

import 'package:image/image.dart' as img;

import '../../../core/logging/app_logger.dart';
import '../domain/models/scan_models.dart';

final _log = AppLogger('CornerSeed');

/// Classical auto-corner heuristic. No ML, no native deps.
///
/// Strategy:
///   1. Downscale to ~512 px long edge.
///   2. Grayscale + light blur.
///   3. Sobel magnitude → threshold at 60th-percentile to get an edge
///      mask that picks out the page border.
///   4. For each row, find the leftmost & rightmost edge pixels;
///      likewise for each column → the bounding quadrilateral of the
///      edge cloud.
///   5. Return the four extrema as normalised corners (0..1).
///
/// This is deliberately simple — it gives the user a *sensible starting
/// point* for the manual corner editor. For badly-lit photos it may
/// degrade to a full-frame crop, which is also what the user would get
/// from Corners.inset().
class ClassicalCornerSeed {
  const ClassicalCornerSeed();

  Future<Corners> seed(String imagePath) async {
    final sw = Stopwatch()..start();
    try {
      final bytes = await File(imagePath).readAsBytes();
      final decoded = img.decodeImage(bytes);
      if (decoded == null) {
        _log.w('decode failed, using inset');
        return Corners.inset();
      }

      // 1. Downscale.
      final longEdge = math.max(decoded.width, decoded.height);
      const target = 512;
      final scale = longEdge > target ? target / longEdge : 1.0;
      final small = scale < 1.0
          ? img.copyResize(
              decoded,
              width: (decoded.width * scale).round(),
              height: (decoded.height * scale).round(),
              interpolation: img.Interpolation.linear,
            )
          : decoded;

      // 2. Grayscale + blur.
      final gray = img.grayscale(img.gaussianBlur(img.Image.from(small), radius: 2));

      // 3. Sobel magnitude.
      final w = gray.width;
      final h = gray.height;
      final mag = List<int>.filled(w * h, 0);
      for (var y = 1; y < h - 1; y++) {
        for (var x = 1; x < w - 1; x++) {
          final tl = gray.getPixel(x - 1, y - 1).r;
          final tm = gray.getPixel(x, y - 1).r;
          final tr = gray.getPixel(x + 1, y - 1).r;
          final ml = gray.getPixel(x - 1, y).r;
          final mr = gray.getPixel(x + 1, y).r;
          final bl = gray.getPixel(x - 1, y + 1).r;
          final bm = gray.getPixel(x, y + 1).r;
          final br = gray.getPixel(x + 1, y + 1).r;
          final gx = (-tl - 2 * ml - bl + tr + 2 * mr + br).toDouble();
          final gy = (-tl - 2 * tm - tr + bl + 2 * bm + br).toDouble();
          mag[y * w + x] = math.sqrt(gx * gx + gy * gy).round().clamp(0, 255);
        }
      }

      // 4. Threshold at 60th-percentile of non-zero magnitudes.
      final sorted = [...mag.where((v) => v > 0)]..sort();
      if (sorted.isEmpty) {
        _log.d('no edges, using inset');
        return Corners.inset();
      }
      final threshold = sorted[(sorted.length * 0.6).floor()];

      // 5. Row / col extrema of the edge cloud.
      var minX = w, maxX = 0, minY = h, maxY = 0;
      var hits = 0;
      for (var y = 0; y < h; y++) {
        for (var x = 0; x < w; x++) {
          if (mag[y * w + x] >= threshold) {
            if (x < minX) minX = x;
            if (x > maxX) maxX = x;
            if (y < minY) minY = y;
            if (y > maxY) maxY = y;
            hits++;
          }
        }
      }
      if (hits < 50 || maxX <= minX || maxY <= minY) {
        _log.d('sparse edges, using inset');
        return Corners.inset();
      }

      // Convert to normalised coords.
      final nxMin = (minX / (w - 1)).clamp(0.0, 1.0);
      final nxMax = (maxX / (w - 1)).clamp(0.0, 1.0);
      final nyMin = (minY / (h - 1)).clamp(0.0, 1.0);
      final nyMax = (maxY / (h - 1)).clamp(0.0, 1.0);

      // Tiny inward nudge so we don't clip the detected page edge.
      const pad = 0.005;
      final corners = Corners(
        Point2((nxMin + pad).clamp(0.0, 1.0), (nyMin + pad).clamp(0.0, 1.0)),
        Point2((nxMax - pad).clamp(0.0, 1.0), (nyMin + pad).clamp(0.0, 1.0)),
        Point2((nxMax - pad).clamp(0.0, 1.0), (nyMax - pad).clamp(0.0, 1.0)),
        Point2((nxMin + pad).clamp(0.0, 1.0), (nyMax - pad).clamp(0.0, 1.0)),
      );
      _log.i('seeded', {
        'ms': sw.elapsedMilliseconds,
        'rect': '$minX,$minY,$maxX,$maxY',
        'hits': hits,
      });
      return corners;
    } catch (e, st) {
      _log.w('seed failed', {'err': e.toString()});
      _log.d('stack', st);
      return Corners.inset();
    }
  }
}
