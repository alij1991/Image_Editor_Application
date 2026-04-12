import 'dart:math' as math;

/// A monotonic tone curve defined by control points in [0,1]^2.
///
/// The curve is evaluated via monotonic cubic interpolation
/// (Hermite-Fritsch-Carlson) so the shape never overshoots or oscillates
/// the way a naive cubic can. [points] must be sorted by x and contain at
/// least two entries (the endpoints).
class ToneCurve {
  ToneCurve(List<CurvePoint> points)
      : points = List.unmodifiable(_sanitize(points));

  /// Identity: a line from (0,0) to (1,1).
  factory ToneCurve.identity() => ToneCurve([
        const CurvePoint(0, 0),
        const CurvePoint(1, 1),
      ]);

  /// A fixed 'S-curve' useful for contrast boosts and testing.
  factory ToneCurve.sCurve([double strength = 0.15]) => ToneCurve([
        const CurvePoint(0, 0),
        CurvePoint(0.25, 0.25 - strength),
        CurvePoint(0.75, 0.75 + strength),
        const CurvePoint(1, 1),
      ]);

  final List<CurvePoint> points;

  /// Evaluate the curve at [x] in [0,1]. Clamped outside the range.
  double evaluate(double x) {
    if (x <= points.first.x) return points.first.y;
    if (x >= points.last.x) return points.last.y;
    // Find the segment.
    int lo = 0;
    int hi = points.length - 1;
    while (hi - lo > 1) {
      final mid = (lo + hi) >> 1;
      if (points[mid].x <= x) {
        lo = mid;
      } else {
        hi = mid;
      }
    }
    final a = points[lo];
    final b = points[hi];
    // Hermite interpolation with monotonic tangents computed via
    // Fritsch-Carlson over the neighboring segments.
    final m0 = _tangent(lo);
    final m1 = _tangent(hi);
    final dx = b.x - a.x;
    final t = (x - a.x) / dx;
    final t2 = t * t;
    final t3 = t2 * t;
    final h00 = 2 * t3 - 3 * t2 + 1;
    final h10 = t3 - 2 * t2 + t;
    final h01 = -2 * t3 + 3 * t2;
    final h11 = t3 - t2;
    return h00 * a.y + h10 * dx * m0 + h01 * b.y + h11 * dx * m1;
  }

  double _tangent(int i) {
    if (points.length == 1) return 0;
    if (i == 0) return _slope(0, 1);
    if (i == points.length - 1) {
      return _slope(points.length - 2, points.length - 1);
    }
    final a = _slope(i - 1, i);
    final b = _slope(i, i + 1);
    if (a * b <= 0) return 0;
    final avg = (a + b) / 2;
    // Clamp to avoid overshoot (Fritsch-Carlson).
    return math.min(avg, math.min(3 * a, 3 * b));
  }

  double _slope(int i, int j) {
    final a = points[i];
    final b = points[j];
    return (b.y - a.y) / (b.x - a.x).clamp(1e-9, 1.0);
  }

  static List<CurvePoint> _sanitize(List<CurvePoint> src) {
    if (src.length < 2) {
      throw ArgumentError('ToneCurve needs at least two points');
    }
    final sorted = [...src]..sort((a, b) => a.x.compareTo(b.x));
    return sorted;
  }
}

class CurvePoint {
  const CurvePoint(this.x, this.y);
  final double x;
  final double y;
}
