import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'box_blur.dart';

/// Rasterises a closed polygon into a Float32 alpha mask.
///
/// Used by beauty services that get a landmark polygon from Face Mesh
/// — the precise inner-mouth ring for teeth whitening, the eye ring
/// for eye brightening, the face oval for skin smoothing.
///
/// Pipeline:
///   1. Clip iteration to the polygon's bounding box — so a 20-point
///      inner-mouth ring on a 2 048 × 1 536 image only touches the
///      ~30×20 pixels it actually covers.
///   2. Point-in-polygon per pixel via ray-casting (O(vertices) per
///      pixel; vertices ≤ 40 for every polygon we use).
///   3. Optional soft edge via a small box blur on an RGBA8 adapter
///      buffer, kept separate from the main Float32 path so the blur
///      helper stays reusable.
///
/// Kept pure-Dart + no `dart:ui` dependency beyond [ui.Offset] so it's
/// isolate-safe and unit-testable without a Flutter binding.
class PolygonMaskBuilder {
  const PolygonMaskBuilder._();

  /// Build a `width × height` Float32 alpha mask in `[0, 1]` from a
  /// closed polygon.
  ///
  /// - [polygon]: ordered vertices in image-pixel coordinates. The
  ///   polygon is implicitly closed (first vertex reconnects to
  ///   last) — callers should NOT duplicate the first point.
  /// - [featherRadius]: half-width of the soft edge in pixels. `0`
  ///   gives a hard 0/1 mask; 2–4 px is the sweet spot for landmark
  ///   polygons on preview-quality buffers.
  /// - Points outside the image are clipped implicitly by the bbox
  ///   iteration window.
  static Float32List build({
    required List<ui.Offset> polygon,
    required int width,
    required int height,
    int featherRadius = 2,
  }) {
    if (width <= 0 || height <= 0) {
      throw ArgumentError('width/height must be > 0');
    }
    if (featherRadius < 0) {
      throw ArgumentError('featherRadius must be >= 0');
    }
    final mask = Float32List(width * height);
    if (polygon.length < 3) return mask; // degenerate

    // 1. Compute polygon bbox clipped to image.
    double minX = polygon.first.dx;
    double minY = polygon.first.dy;
    double maxX = minX;
    double maxY = minY;
    for (final p in polygon) {
      if (p.dx < minX) minX = p.dx;
      if (p.dx > maxX) maxX = p.dx;
      if (p.dy < minY) minY = p.dy;
      if (p.dy > maxY) maxY = p.dy;
    }
    // Pad by featherRadius so the blur has room to ramp up.
    final pad = featherRadius.toDouble();
    final x0 = math.max(0, (minX - pad).floor());
    final y0 = math.max(0, (minY - pad).floor());
    final x1 = math.min(width - 1, (maxX + pad).ceil());
    final y1 = math.min(height - 1, (maxY + pad).ceil());
    if (x1 < x0 || y1 < y0) return mask;

    // 2. Rasterise hard mask into the bbox.
    for (int y = y0; y <= y1; y++) {
      final yd = y.toDouble() + 0.5;
      for (int x = x0; x <= x1; x++) {
        final xd = x.toDouble() + 0.5;
        if (_pointInPolygon(xd, yd, polygon)) {
          mask[y * width + x] = 1.0;
        }
      }
    }

    if (featherRadius == 0) return mask;

    // 3. Feather via a small box blur on the bbox subregion. Wrapping
    //    the Float32 values in a temporary RGBA buffer lets us reuse
    //    [BoxBlur] — cheap given the small bbox and the fact that
    //    only the R channel carries signal.
    final bw = x1 - x0 + 1;
    final bh = y1 - y0 + 1;
    final tile = Uint8List(bw * bh * 4);
    for (int y = 0; y < bh; y++) {
      final src = (y + y0) * width + x0;
      final dst = y * bw * 4;
      for (int x = 0; x < bw; x++) {
        final v = mask[src + x];
        final b = (v * 255).round().clamp(0, 255);
        tile[dst + x * 4] = b; // R
        tile[dst + x * 4 + 1] = b; // G (unused — kept consistent)
        tile[dst + x * 4 + 2] = b; // B
        tile[dst + x * 4 + 3] = 255; // A
      }
    }
    final blurred = BoxBlur.blurRgba(
      source: tile,
      width: bw,
      height: bh,
      radius: featherRadius,
    );
    // Copy the blurred R channel back into the float mask.
    for (int y = 0; y < bh; y++) {
      final dst = (y + y0) * width + x0;
      final src = y * bw * 4;
      for (int x = 0; x < bw; x++) {
        mask[dst + x] = blurred[src + x * 4] / 255.0;
      }
    }
    return mask;
  }

  /// Standard ray-casting point-in-polygon. Vertices are treated as
  /// an implicit closed loop (last vertex connects back to first).
  static bool _pointInPolygon(double x, double y, List<ui.Offset> poly) {
    bool inside = false;
    final n = poly.length;
    for (int i = 0, j = n - 1; i < n; j = i++) {
      final pi = poly[i];
      final pj = poly[j];
      final yi = pi.dy;
      final yj = pj.dy;
      if ((yi > y) != (yj > y)) {
        final intersectX = (pj.dx - pi.dx) * (y - yi) / (yj - yi) + pi.dx;
        if (x < intersectX) inside = !inside;
      }
    }
    return inside;
  }

  /// Max-combine a polygon mask into an existing Float32 mask. Used
  /// when a service needs the UNION of multiple polygons (e.g.
  /// eye-ring + pupil ring, or upper-lip + lower-lip rings).
  static void stampInto({
    required Float32List target,
    required List<ui.Offset> polygon,
    required int width,
    required int height,
    int featherRadius = 2,
  }) {
    final stamp = build(
      polygon: polygon,
      width: width,
      height: height,
      featherRadius: featherRadius,
    );
    for (int i = 0; i < target.length; i++) {
      if (stamp[i] > target[i]) target[i] = stamp[i];
    }
  }
}
