import 'dart:math' as math;
import 'dart:ui' show Offset;

/// Phase XVI.61 — text on path, math layer.
///
/// Pure-Dart Bezier glyph layout. Given a chain of cubic Beziers and
/// a list of glyph advance widths, returns the (position, tangent)
/// of every glyph laid out along the path. The renderer's
/// `TextPainter` integration uses these to draw each glyph rotated
/// to match the path's local tangent — Procreate added this in 2024
/// and Photoshop / Illustrator have shipped it forever.
///
/// ## What ships in XVI.61
///
/// 1. [CubicBezier] — a single 4-control-point segment.
/// 2. [BezierPath] — an ordered chain of cubic segments. Carries an
///    arc-length lookup table for O(log n) `sampleAt` queries.
/// 3. [GlyphPlacement] — output row: pen origin + tangent angle.
/// 4. [TextPathLayout.layout] — top-level entry; walks glyph widths
///    along the path and returns one placement per fitted glyph.
///    Glyphs that would extend past the path's end are silently
///    dropped.
///
/// ## What does NOT ship in XVI.61
///
/// The painter integration — calling [TextPainter] per glyph and
/// rotating the canvas at each placement — is a small UI follow-up
/// (XVI.61.1) that builds atop these primitives. Same scoping
/// pattern as XVI.60: ship the math + data, leave the surface
/// integration as an explicit next-step PR.
class CubicBezier {
  /// `(p0, p3)` are the on-curve endpoints; `(p1, p2)` are the
  /// off-curve handles. Standard cubic form.
  const CubicBezier({
    required this.p0,
    required this.p1,
    required this.p2,
    required this.p3,
  });

  final Offset p0;
  final Offset p1;
  final Offset p2;
  final Offset p3;

  /// Construct a degenerate-straight cubic from two points. The
  /// handles sit one-third of the way along the line so the
  /// tangent at every t is the line's direction. Useful as a
  /// fallback when the user just wants a straight baseline.
  factory CubicBezier.line(Offset a, Offset b) {
    final dx = b.dx - a.dx;
    final dy = b.dy - a.dy;
    return CubicBezier(
      p0: a,
      p1: Offset(a.dx + dx / 3, a.dy + dy / 3),
      p2: Offset(a.dx + 2 * dx / 3, a.dy + 2 * dy / 3),
      p3: b,
    );
  }

  /// Position at parametric `t ∈ [0, 1]`. Standard de Casteljau /
  /// Bernstein expansion.
  Offset pointAt(double t) {
    final mt = 1 - t;
    final a = mt * mt * mt;
    final b = 3 * mt * mt * t;
    final c = 3 * mt * t * t;
    final d = t * t * t;
    return Offset(
      a * p0.dx + b * p1.dx + c * p2.dx + d * p3.dx,
      a * p0.dy + b * p1.dy + c * p2.dy + d * p3.dy,
    );
  }

  /// First derivative at parametric `t`. Returns the unscaled
  /// tangent vector — the magnitude is the speed of parameter
  /// progress, NOT the unit tangent. Callers that need the angle
  /// take `atan2(dy, dx)`.
  Offset derivativeAt(double t) {
    final mt = 1 - t;
    return Offset(
      3 * mt * mt * (p1.dx - p0.dx) +
          6 * mt * t * (p2.dx - p1.dx) +
          3 * t * t * (p3.dx - p2.dx),
      3 * mt * mt * (p1.dy - p0.dy) +
          6 * mt * t * (p2.dy - p1.dy) +
          3 * t * t * (p3.dy - p2.dy),
    );
  }
}

/// An ordered chain of cubic Beziers. Empty paths are not allowed.
///
/// On construction, the path is sampled into [_arcLut] — a table
/// of (cumulative arc length → segmentIndex, t) tuples — so
/// [sampleAt] is an O(log n) binary search instead of a linear
/// walk. The default [samplesPerSegment] of 32 keeps placements
/// within ~0.5 px of the analytic curve for typical font sizes,
/// which is well below the visual threshold.
class BezierPath {
  BezierPath({
    required this.segments,
    int samplesPerSegment = 32,
  }) {
    if (segments.isEmpty) {
      throw ArgumentError('BezierPath must have at least one segment');
    }
    if (samplesPerSegment < 2) {
      throw ArgumentError('samplesPerSegment must be ≥ 2');
    }
    _samplesPerSegment = samplesPerSegment;
    _buildLut();
  }

  final List<CubicBezier> segments;
  late final int _samplesPerSegment;

  /// Precomputed `(arc length, segmentIndex, t)` triples. Strictly
  /// monotonic in arc length.
  late final List<_ArcSample> _arcLut;

  void _buildLut() {
    final samples = <_ArcSample>[];
    var cum = 0.0;
    samples.add(const _ArcSample(s: 0.0, segmentIndex: 0, t: 0.0));
    for (var i = 0; i < segments.length; i++) {
      // Explicit "segment start" marker for every segment after the
      // first. At a corner, two consecutive samples share the same
      // arc length but point at different (segIdx, t). The binary
      // search uses a `<=` walk so it lands on the LATER marker —
      // i.e., the start of the new segment — which is exactly the
      // tangent the user expects: glyphs at the join lean into the
      // upcoming direction, not the trailing one.
      if (i > 0) {
        samples.add(_ArcSample(s: cum, segmentIndex: i, t: 0.0));
      }
      final seg = segments[i];
      Offset prev = seg.p0;
      for (var j = 1; j <= _samplesPerSegment; j++) {
        final t = j / _samplesPerSegment;
        final p = seg.pointAt(t);
        cum += (p - prev).distance;
        samples.add(_ArcSample(s: cum, segmentIndex: i, t: t));
        prev = p;
      }
    }
    _arcLut = samples;
  }

  /// Total arc length of the path (linear approximation; same
  /// budget as the LUT).
  double get totalLength => _arcLut.last.s;

  /// Convenience constructor for a straight line — single cubic.
  factory BezierPath.line(Offset a, Offset b) =>
      BezierPath(segments: [CubicBezier.line(a, b)]);

  /// Sample the path at arc-length [s]. Out-of-range queries clamp
  /// to the nearest endpoint (no NaN propagation). Returns the
  /// position + tangent angle in radians.
  PathSample sampleAt(double s) {
    if (_arcLut.length < 2) {
      // Defensive — _buildLut always emits at least 2 samples.
      final seg = segments.first;
      return PathSample(position: seg.p0, tangentRadians: 0.0);
    }
    if (s <= _arcLut.first.s) {
      return _interpolate(_arcLut.first, _arcLut.first, 0.0);
    }
    if (s >= _arcLut.last.s) {
      return _interpolate(_arcLut.last, _arcLut.last, 0.0);
    }
    // Binary search for the bracketing pair.
    var lo = 0;
    var hi = _arcLut.length - 1;
    while (lo + 1 < hi) {
      final mid = (lo + hi) ~/ 2;
      if (_arcLut[mid].s <= s) {
        lo = mid;
      } else {
        hi = mid;
      }
    }
    final aSeg = _arcLut[lo];
    final bSeg = _arcLut[hi];
    final span = bSeg.s - aSeg.s;
    final f = span <= 0 ? 0.0 : (s - aSeg.s) / span;
    return _interpolate(aSeg, bSeg, f);
  }

  PathSample _interpolate(_ArcSample a, _ArcSample b, double f) {
    // The interpolation parameter `f` walks linearly through the
    // sample chain. When a == b we fall back to the analytic
    // sample at a.t directly — no division by zero.
    final segIdx = a.segmentIndex;
    final tA = a.t;
    final tB = (b.segmentIndex == segIdx) ? b.t : 1.0;
    final t = tA + f * (tB - tA);
    final seg = segments[segIdx];
    final p = seg.pointAt(t);
    final d = seg.derivativeAt(t);
    final theta = math.atan2(d.dy, d.dx);
    return PathSample(position: p, tangentRadians: theta);
  }
}

/// One `(arc length, segment index, t)` triple from the LUT.
class _ArcSample {
  const _ArcSample({
    required this.s,
    required this.segmentIndex,
    required this.t,
  });
  final double s;
  final int segmentIndex;
  final double t;
}

/// Output of [BezierPath.sampleAt]. The `position` is in the same
/// coordinate space the path was built in (typically image pixels);
/// `tangentRadians` is the angle of the curve tangent measured
/// CCW from the +x axis.
class PathSample {
  const PathSample({
    required this.position,
    required this.tangentRadians,
  });

  final Offset position;
  final double tangentRadians;

  @override
  bool operator ==(Object other) =>
      other is PathSample &&
      other.position == position &&
      other.tangentRadians == tangentRadians;

  @override
  int get hashCode => Object.hash(position, tangentRadians);
}

/// Where to draw one glyph along the path.
class GlyphPlacement {
  const GlyphPlacement({
    required this.position,
    required this.tangentRadians,
    required this.advance,
    required this.glyphIndex,
  });

  /// Pen origin — the baseline-left point of the glyph in the
  /// path's coordinate space.
  final Offset position;

  /// Angle in radians, CCW from +x. The painter typically rotates
  /// the canvas by this then draws the glyph.
  final double tangentRadians;

  /// Width of this glyph in the same units as the path. Forwarded
  /// from the input `glyphWidths` so callers can paint the glyph
  /// without re-measuring.
  final double advance;

  /// Position of this glyph in the original `glyphWidths` list.
  /// Stable across overflow drops — if the path can fit only the
  /// first 7 of 10 glyphs, you still get glyphIndex = 0..6.
  final int glyphIndex;

  @override
  bool operator ==(Object other) =>
      other is GlyphPlacement &&
      other.position == position &&
      other.tangentRadians == tangentRadians &&
      other.advance == advance &&
      other.glyphIndex == glyphIndex;

  @override
  int get hashCode =>
      Object.hash(position, tangentRadians, advance, glyphIndex);
}

class TextPathLayout {
  TextPathLayout._();

  /// Lay glyphs out along [path]. The cursor starts at arc length
  /// [startOffset] (default 0). Each glyph is anchored at the
  /// cursor's current position; the cursor advances by the glyph's
  /// width before the next glyph is placed. Glyphs that would
  /// extend past the path's end are silently dropped (overflow
  /// handling — Procreate / Illustrator both do this).
  ///
  /// [letterSpacing] is added to every advance, post-glyph.
  /// Negative values are honoured — Photoshop allows kerning
  /// adjustments on path-laid text.
  static List<GlyphPlacement> layout({
    required BezierPath path,
    required List<double> glyphWidths,
    double startOffset = 0.0,
    double letterSpacing = 0.0,
  }) {
    if (glyphWidths.isEmpty) return const [];
    final total = path.totalLength;
    var cursor = startOffset;
    final placements = <GlyphPlacement>[];
    for (var i = 0; i < glyphWidths.length; i++) {
      final w = glyphWidths[i];
      if (w < 0) {
        throw ArgumentError(
          'glyphWidths[$i] = $w; widths must be ≥ 0',
        );
      }
      // Drop the glyph if it can't fit. Note we test against the
      // FAR edge of the glyph (`cursor + w`) so a glyph that
      // exactly fills the remaining length is still drawn.
      if (cursor < 0 || cursor > total || cursor + w > total + 1e-6) {
        // Stop placing once the first glyph fails — the rest
        // can't fit either. (`break` rather than `continue` —
        // partial mid-string drops would be visually surprising.)
        break;
      }
      final s = path.sampleAt(cursor);
      placements.add(GlyphPlacement(
        position: s.position,
        tangentRadians: s.tangentRadians,
        advance: w,
        glyphIndex: i,
      ));
      cursor += w + letterSpacing;
    }
    return placements;
  }
}
