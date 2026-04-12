import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

/// One feathered circle stamp in source-image pixel coordinates.
/// Used by [LandmarkMaskBuilder] to build eye and mouth masks from
/// face-landmark points.
class LandmarkSpot {
  const LandmarkSpot({required this.center, required this.radius});

  /// Center of the circle in image pixels.
  final ui.Offset center;

  /// Radius of the full-alpha core plus feather ramp.
  final double radius;
}

/// Builds a single-channel alpha mask where each [LandmarkSpot] is
/// rendered as a feathered circle. Used by Phase 9e's eye brightening
/// and teeth whitening services — both need to apply a pixel-level
/// RGB op inside tight landmark-shaped regions while leaving the
/// rest of the image untouched.
///
/// Pure Dart, no `dart:ui` except for [ui.Offset] as an input type,
/// so the builder is isolate-safe and fully unit-testable.
class LandmarkMaskBuilder {
  const LandmarkMaskBuilder._();

  /// Build a `width × height` Float32List mask in `[0, 1]`.
  ///
  /// - [feather] controls the width of the soft falloff as a
  ///   fraction of the radius. `0` = hard edge, `1` = the full
  ///   radius is a gradient. Defaults to `0.5` — tight enough to
  ///   not bleed onto surrounding skin but soft enough that the
  ///   composite seam is invisible.
  /// - Overlapping spots use max-combine so two adjacent eyes don't
  ///   additively over-brighten where their circles touch.
  /// - An empty spot list returns an all-zero mask.
  static Float32List build({
    required List<LandmarkSpot> spots,
    required int width,
    required int height,
    double feather = 0.5,
  }) {
    if (width <= 0 || height <= 0) {
      throw ArgumentError('width and height must be > 0');
    }
    if (feather < 0 || feather > 1) {
      throw ArgumentError('feather must be in [0, 1]');
    }

    final mask = Float32List(width * height);
    if (spots.isEmpty) return mask;

    for (final spot in spots) {
      _stampCircle(
        mask: mask,
        width: width,
        height: height,
        spot: spot,
        feather: feather,
      );
    }
    return mask;
  }

  // ----- internals ---------------------------------------------------------

  static void _stampCircle({
    required Float32List mask,
    required int width,
    required int height,
    required LandmarkSpot spot,
    required double feather,
  }) {
    final cx = spot.center.dx;
    final cy = spot.center.dy;
    final r = spot.radius;
    if (r <= 0) return;

    // Clip to a bounding box so we don't walk the whole image.
    final x0 = (cx - r).clamp(0.0, (width - 1).toDouble()).floor();
    final x1 = (cx + r).clamp(0.0, (width - 1).toDouble()).ceil();
    final y0 = (cy - r).clamp(0.0, (height - 1).toDouble()).floor();
    final y1 = (cy + r).clamp(0.0, (height - 1).toDouble()).ceil();

    // Feather starts at `r * (1 - feather)` and ramps out at `r`.
    final hardR2 = math.pow(r * (1 - feather), 2).toDouble();
    final softR2 = r * r;

    for (int y = y0; y <= y1; y++) {
      final dy = y - cy;
      for (int x = x0; x <= x1; x++) {
        final dx = x - cx;
        final d2 = dx * dx + dy * dy;
        if (d2 > softR2) continue;
        double alpha;
        if (d2 <= hardR2) {
          alpha = 1;
        } else {
          // Smoothstep on the feather ring.
          final d = math.sqrt(d2);
          final t = ((r - d) / (r * feather)).clamp(0.0, 1.0);
          alpha = _smoothstep(t);
        }
        if (alpha <= 0) continue;
        final idx = y * width + x;
        if (alpha > mask[idx]) mask[idx] = alpha;
      }
    }
  }

  static double _smoothstep(double t) {
    if (t <= 0) return 0;
    if (t >= 1) return 1;
    return t * t * (3 - 2 * t);
  }
}
