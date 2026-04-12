import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

/// One anchor point in a face-reshape warp field.
///
/// `source` marks a point in the ORIGINAL image (e.g. a contour
/// point from ML Kit) that we want to effectively move to
/// `target`. `radius` sets the falloff distance — pixels within the
/// radius are displaced proportionally, pixels outside are
/// untouched. Multiple anchors are summed with a smoothstep
/// weighting so the warp stays continuous across anchor
/// boundaries.
///
/// Displacement semantics are **forward**: `source + δ → target`,
/// where `δ = target - source`. The [ImageWarper] then does a
/// standard inverse-mapping resample: for each destination pixel
/// it computes the total displacement at that pixel and samples
/// the source at `(dst - δ)`.
class WarpAnchor {
  const WarpAnchor({
    required this.source,
    required this.target,
    required this.radius,
  });

  final ui.Offset source;
  final ui.Offset target;
  final double radius;

  ui.Offset get displacement => target - source;
}

/// Pure-Dart RGBA image warper used by Phase 9f's face reshape
/// pipeline. Produces a new buffer of the same dimensions via
/// inverse-mapping with bilinear sampling.
///
/// Two-phase algorithm:
///   1. **Accumulation**: walk each [WarpAnchor] and add a
///      smoothstep-weighted displacement contribution into a
///      flat `width*height*2` Float32List. Per-anchor cost is
///      bounded to its bounding-box (`radius`), not the whole
///      image, so many small anchors stay cheap.
///   2. **Resample**: for each destination pixel, look up the
///      displacement, compute `src = dst - δ`, and bilinear-sample
///      the source. Edge pixels are clamp-extended so the output
///      never has black borders.
///
/// Returns a fresh `Uint8List` — the input buffer is never mutated.
/// Alpha is always copied from the sampled source pixel, so warped
/// cutouts retain their opacity.
class ImageWarper {
  const ImageWarper._();

  /// Warp [source] by [anchors]. Returns a new RGBA8 buffer of
  /// the same dimensions.
  ///
  /// Throws [ArgumentError] on invalid buffer length or
  /// non-positive dimensions.
  static Uint8List apply({
    required Uint8List source,
    required int width,
    required int height,
    required List<WarpAnchor> anchors,
  }) {
    if (width <= 0 || height <= 0) {
      throw ArgumentError('width and height must be > 0');
    }
    if (source.length != width * height * 4) {
      throw ArgumentError(
        'source length ${source.length} != ${width * height * 4}',
      );
    }
    if (anchors.isEmpty) {
      // No anchors → return an exact copy (documented semantics).
      return Uint8List.fromList(source);
    }

    // Displacement field in forward form: for each pixel, the
    // aggregate (dx, dy) that pulls it from its canonical location
    // toward the target. Stored row-major as [dx0, dy0, dx1, dy1,…].
    final field = Float32List(width * height * 2);
    // Weight accumulator so we can normalize when multiple anchors
    // influence the same pixel (otherwise stacking nearby anchors
    // would over-displace).
    final weightSum = Float32List(width * height);

    for (final anchor in anchors) {
      _accumulateAnchor(
        field: field,
        weightSum: weightSum,
        width: width,
        height: height,
        anchor: anchor,
      );
    }

    // Normalize accumulated displacement by total weight so
    // overlapping anchors average cleanly rather than sum.
    for (int i = 0; i < weightSum.length; i++) {
      final w = weightSum[i];
      if (w > 0) {
        final o = i * 2;
        field[o] /= w;
        field[o + 1] /= w;
      }
    }

    // Resample: for each destination pixel, sample the source at
    // (dst - displacement). Bilinear with clamped edges.
    final out = Uint8List(source.length);
    for (int y = 0; y < height; y++) {
      for (int x = 0; x < width; x++) {
        final fieldIdx = y * width + x;
        final dx = field[fieldIdx * 2];
        final dy = field[fieldIdx * 2 + 1];
        final sx = x - dx;
        final sy = y - dy;
        final outIdx = fieldIdx * 4;
        _bilinearSample(
          source: source,
          width: width,
          height: height,
          sx: sx,
          sy: sy,
          out: out,
          outIdx: outIdx,
        );
      }
    }
    return out;
  }

  static void _accumulateAnchor({
    required Float32List field,
    required Float32List weightSum,
    required int width,
    required int height,
    required WarpAnchor anchor,
  }) {
    final r = anchor.radius;
    if (r <= 0) return;
    final cx = anchor.source.dx;
    final cy = anchor.source.dy;
    final dispDx = anchor.target.dx - anchor.source.dx;
    final dispDy = anchor.target.dy - anchor.source.dy;

    // Clip iteration to the anchor's bounding box (intersected
    // with the image bounds) so cost is O(r²), not O(w*h).
    final x0 = (cx - r).clamp(0.0, (width - 1).toDouble()).floor();
    final x1 = (cx + r).clamp(0.0, (width - 1).toDouble()).ceil();
    final y0 = (cy - r).clamp(0.0, (height - 1).toDouble()).floor();
    final y1 = (cy + r).clamp(0.0, (height - 1).toDouble()).ceil();
    if (x1 < x0 || y1 < y0) return;
    final r2 = r * r;

    for (int y = y0; y <= y1; y++) {
      final ddy = y - cy;
      for (int x = x0; x <= x1; x++) {
        final ddx = x - cx;
        final d2 = ddx * ddx + ddy * ddy;
        if (d2 > r2) continue;
        final d = math.sqrt(d2);
        // Smoothstep falloff: 1 at center, 0 at radius. Pulls
        // stronger near the anchor and smoothly releases at the
        // rim so the warp doesn't seam.
        final t = 1 - (d / r);
        final w = t * t * (3 - 2 * t);
        if (w <= 0) continue;
        final idx = y * width + x;
        field[idx * 2] += dispDx * w;
        field[idx * 2 + 1] += dispDy * w;
        weightSum[idx] += w;
      }
    }
  }

  /// Bilinear sample [source] at (sx, sy) and write an RGBA pixel
  /// into [out] starting at [outIdx]. Clamps to the image bounds so
  /// warps that pull from outside the frame get the nearest-edge
  /// pixel rather than transparent or garbage.
  static void _bilinearSample({
    required Uint8List source,
    required int width,
    required int height,
    required double sx,
    required double sy,
    required Uint8List out,
    required int outIdx,
  }) {
    // Clamp to [0, width-1] × [0, height-1] so sampling is well-
    // defined even at the frame edges.
    double cx = sx;
    double cy = sy;
    if (cx < 0) cx = 0;
    if (cy < 0) cy = 0;
    final maxX = (width - 1).toDouble();
    final maxY = (height - 1).toDouble();
    if (cx > maxX) cx = maxX;
    if (cy > maxY) cy = maxY;

    final x0 = cx.floor();
    final y0 = cy.floor();
    final x1 = x0 + 1 > width - 1 ? width - 1 : x0 + 1;
    final y1 = y0 + 1 > height - 1 ? height - 1 : y0 + 1;
    final fx = cx - x0;
    final fy = cy - y0;
    final w00 = (1 - fx) * (1 - fy);
    final w10 = fx * (1 - fy);
    final w01 = (1 - fx) * fy;
    final w11 = fx * fy;

    final i00 = (y0 * width + x0) * 4;
    final i10 = (y0 * width + x1) * 4;
    final i01 = (y1 * width + x0) * 4;
    final i11 = (y1 * width + x1) * 4;

    for (int c = 0; c < 4; c++) {
      final v = source[i00 + c] * w00 +
          source[i10 + c] * w10 +
          source[i01 + c] * w01 +
          source[i11 + c] * w11;
      out[outIdx + c] = v < 0 ? 0 : (v > 255 ? 255 : v.round());
    }
  }
}
