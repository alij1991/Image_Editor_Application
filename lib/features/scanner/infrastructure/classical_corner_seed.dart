import 'dart:io';
import 'dart:math' as math;

import 'package:image/image.dart' as img;

import '../../../core/logging/app_logger.dart';
import '../domain/models/scan_models.dart';

final _log = AppLogger('CornerSeed');

/// Outcome of a single seed attempt. [fellBack] is true when the
/// heuristic couldn't find usable edges and returned a default inset
/// rect instead — the UI surfaces a coaching banner in that case so
/// the user knows to drag the corners themselves.
class SeedResult {
  const SeedResult({required this.corners, required this.fellBack});

  final Corners corners;
  final bool fellBack;
}

/// Common surface every corner-seeding strategy implements. Lets the
/// notifier swap between the OpenCV contour detector, the Sobel
/// heuristic, or any future ML-based seeder without changing call
/// sites.
///
/// **Phase V.9**: adds [seedBatch] for multi-page gallery imports.
/// Implementers that can amortize setup across pages (e.g.
/// [OpenCvCornerSeed], which can run the whole batch in one worker
/// isolate) override it; the rest inherit the default parallel
/// forwarder below.
///
/// **Phase VI.7**: the default forwarder moved from sequential
/// `for+await` to [Future.wait] — a different axis from V.9's
/// per-batch isolate batching. `seed` typically reads a file off
/// disk (`async` I/O that yields the isolate) before any CPU work;
/// sequential dispatch left those I/O waits serial when firing them
/// in parallel costs nothing beyond the completer overhead. CPU
/// sections still serialise on the main isolate's event loop — the
/// speedup is in the I/O overlap, not the compute. Ordering is
/// preserved (`Future.wait` returns results in iteration order), so
/// `results[i]` still maps to `imagePaths[i]`.
abstract class CornerSeeder {
  const CornerSeeder();

  Future<SeedResult> seed(String imagePath);

  /// Default parallel batch: fire [seed] for every path at once and
  /// await the combined future. Preserves ordering (`results[i]`
  /// corresponds to `imagePaths[i]`).
  Future<List<SeedResult>> seedBatch(List<String> imagePaths) async {
    if (imagePaths.isEmpty) return const [];
    return Future.wait(imagePaths.map(seed));
  }
}

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
class ClassicalCornerSeed extends CornerSeeder {
  const ClassicalCornerSeed();

  // Phase VI.7: inherits the parallel default `seedBatch` from
  // [CornerSeeder]. Pre-VI.7 this class redeclared the sequential
  // forwarder because the `implements` contract required it, but
  // now we `extends` so the default impl is inherited; Sobel's file
  // I/O overlaps per-page instead of serializing.

  @override
  Future<SeedResult> seed(String imagePath) async {
    final sw = Stopwatch()..start();
    try {
      final bytes = await File(imagePath).readAsBytes();
      final decoded = img.decodeImage(bytes);
      if (decoded == null) {
        _log.w('decode failed, using inset');
        return SeedResult(corners: Corners.inset(), fellBack: true);
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
        return SeedResult(corners: Corners.inset(), fellBack: true);
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
        return SeedResult(corners: Corners.inset(), fellBack: true);
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
      // If the bounding box covers nearly the whole frame the heuristic
      // didn't actually find a page — the user just photographed paper
      // edge-to-edge or a textured background. Treat as fell-back so
      // the UI nudges them to drag corners.
      final coverage =
          (nxMax - nxMin).clamp(0.0, 1.0) * (nyMax - nyMin).clamp(0.0, 1.0);
      final fellBack = coverage > 0.95;
      _log.i('seeded', {
        'ms': sw.elapsedMilliseconds,
        'rect': '$minX,$minY,$maxX,$maxY',
        'hits': hits,
        'coverage': coverage.toStringAsFixed(2),
        'fellBack': fellBack,
      });
      return SeedResult(corners: corners, fellBack: fellBack);
    } catch (e, st) {
      _log.w('seed failed', {'err': e.toString()});
      _log.d('stack', st);
      return SeedResult(corners: Corners.inset(), fellBack: true);
    }
  }
}
