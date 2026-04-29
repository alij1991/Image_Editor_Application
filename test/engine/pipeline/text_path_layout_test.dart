import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';

import 'package:image_editor/engine/pipeline/text_path_layout.dart';

/// Phase XVI.61 — text on path math layer.
///
/// Coverage:
///   1. CubicBezier — point + derivative correctness on canonical
///      shapes (line, quarter-circle approximation).
///   2. CubicBezier.line — derivative is the line's direction at
///      every t (no curvature).
///   3. BezierPath — totalLength matches a known straight-line
///      distance; sampleAt clamps out-of-range, monotonic in s.
///   4. BezierPath.sampleAt — tangent angle wraps π/2 at a vertical
///      line, 0 at horizontal.
///   5. TextPathLayout.layout — straight horizontal: positions
///      march at glyph widths, every tangent is 0.
///   6. TextPathLayout.layout — overflow drops trailing glyphs.
///   7. letterSpacing shifts subsequent placements; negative values
///      honoured.
///   8. startOffset shifts the whole run.
///   9. Negative glyph widths throw.
///  10. GlyphPlacement value-class equality.
void main() {
  group('CubicBezier', () {
    test('line cubic — point at any t lies on the segment', () {
      final c = CubicBezier.line(const Offset(0, 0), const Offset(10, 0));
      // Both endpoints + a midpoint lie on the line.
      expect(c.pointAt(0).dx, closeTo(0, 1e-6));
      expect(c.pointAt(0).dy, closeTo(0, 1e-6));
      expect(c.pointAt(0.5).dx, closeTo(5, 1e-6));
      expect(c.pointAt(0.5).dy, closeTo(0, 1e-6));
      expect(c.pointAt(1).dx, closeTo(10, 1e-6));
      expect(c.pointAt(1).dy, closeTo(0, 1e-6));
    });

    test('line cubic — derivative is constant (no curvature)', () {
      final c = CubicBezier.line(const Offset(0, 0), const Offset(10, 0));
      final d0 = c.derivativeAt(0);
      final d5 = c.derivativeAt(0.5);
      final d1 = c.derivativeAt(1);
      // The line's tangent is (10, 0) — the magnitude is the speed
      // of parameter progress, which for our handle placement is
      // 10 (the line endpoint difference).
      expect(d0.dy, closeTo(0, 1e-6));
      expect(d5.dy, closeTo(0, 1e-6));
      expect(d1.dy, closeTo(0, 1e-6));
      // Magnitudes positive — direction along +x.
      expect(d0.dx, greaterThan(0));
      expect(d5.dx, greaterThan(0));
      expect(d1.dx, greaterThan(0));
    });

    test('arbitrary cubic — endpoints land on p0 and p3', () {
      const c = CubicBezier(
        p0: Offset(0, 0),
        p1: Offset(0, 10),
        p2: Offset(10, 10),
        p3: Offset(10, 0),
      );
      expect(c.pointAt(0), const Offset(0, 0));
      expect(c.pointAt(1), const Offset(10, 0));
    });
  });

  group('BezierPath', () {
    test('rejects empty segment list', () {
      expect(() => BezierPath(segments: const []), throwsArgumentError);
    });

    test('rejects samplesPerSegment < 2', () {
      expect(
        () => BezierPath.line(const Offset(0, 0), const Offset(1, 1))
          ..sampleAt(0),
        returnsNormally,
      );
      expect(
        () => BezierPath(
          segments: [CubicBezier.line(const Offset(0, 0), const Offset(1, 1))],
          samplesPerSegment: 1,
        ),
        throwsArgumentError,
      );
    });

    test('totalLength of a straight line matches the endpoints', () {
      final path = BezierPath.line(const Offset(0, 0), const Offset(100, 0));
      expect(path.totalLength, closeTo(100.0, 1e-3));
    });

    test('totalLength of two chained line segments adds up', () {
      final path = BezierPath(
        segments: [
          CubicBezier.line(const Offset(0, 0), const Offset(50, 0)),
          CubicBezier.line(const Offset(50, 0), const Offset(50, 50)),
        ],
      );
      expect(path.totalLength, closeTo(100.0, 1e-2));
    });

    test('sampleAt clamps out-of-range queries', () {
      final path = BezierPath.line(const Offset(0, 0), const Offset(100, 0));
      // Negative s clamps to start.
      final lo = path.sampleAt(-50);
      expect(lo.position.dx, closeTo(0, 1e-3));
      expect(lo.position.dy, closeTo(0, 1e-3));
      // Past-end clamps to end.
      final hi = path.sampleAt(99999);
      expect(hi.position.dx, closeTo(100, 1e-3));
      expect(hi.position.dy, closeTo(0, 1e-3));
    });

    test('sampleAt is monotonic in arc length on a straight line', () {
      final path = BezierPath.line(const Offset(0, 0), const Offset(100, 0));
      var prevX = -1.0;
      for (var i = 0; i <= 10; i++) {
        final s = i * 10.0;
        final p = path.sampleAt(s);
        expect(p.position.dx, greaterThan(prevX));
        prevX = p.position.dx;
      }
    });

    test('sampleAt tangent: horizontal line → angle 0', () {
      final path = BezierPath.line(const Offset(0, 0), const Offset(100, 0));
      expect(path.sampleAt(50).tangentRadians, closeTo(0.0, 1e-3));
    });

    test('sampleAt tangent: vertical line → angle π/2', () {
      final path = BezierPath.line(const Offset(0, 0), const Offset(0, 100));
      expect(path.sampleAt(50).tangentRadians, closeTo(math.pi / 2, 1e-3));
    });

    test('sampleAt tangent: 45° diagonal line → angle π/4', () {
      final path = BezierPath.line(const Offset(0, 0), const Offset(70, 70));
      expect(path.sampleAt(35).tangentRadians, closeTo(math.pi / 4, 1e-3));
    });
  });

  group('TextPathLayout.layout — happy path', () {
    test('horizontal line: positions march at glyph widths', () {
      final path = BezierPath.line(const Offset(0, 0), const Offset(100, 0));
      final placements = TextPathLayout.layout(
        path: path,
        glyphWidths: const [10, 10, 10],
      );
      expect(placements, hasLength(3));
      // Glyph 0 starts at 0, glyph 1 at 10, glyph 2 at 20.
      expect(placements[0].position.dx, closeTo(0.0, 1e-3));
      expect(placements[1].position.dx, closeTo(10.0, 1e-3));
      expect(placements[2].position.dx, closeTo(20.0, 1e-3));
      for (final p in placements) {
        expect(p.position.dy, closeTo(0.0, 1e-3));
        expect(p.tangentRadians, closeTo(0.0, 1e-3));
      }
    });

    test('every placement carries its glyphIndex from the input', () {
      final path = BezierPath.line(const Offset(0, 0), const Offset(100, 0));
      final placements = TextPathLayout.layout(
        path: path,
        glyphWidths: const [5, 5, 5],
      );
      expect(placements.map((p) => p.glyphIndex).toList(), [0, 1, 2]);
    });

    test('letterSpacing shifts subsequent placements', () {
      final path = BezierPath.line(const Offset(0, 0), const Offset(100, 0));
      final placements = TextPathLayout.layout(
        path: path,
        glyphWidths: const [10, 10, 10],
        letterSpacing: 5,
      );
      expect(placements[0].position.dx, closeTo(0.0, 1e-3));
      expect(placements[1].position.dx, closeTo(15.0, 1e-3)); // 10 + 5
      expect(placements[2].position.dx, closeTo(30.0, 1e-3)); // 15 + 10 + 5
    });

    test('negative letterSpacing tightens placements', () {
      final path = BezierPath.line(const Offset(0, 0), const Offset(100, 0));
      final placements = TextPathLayout.layout(
        path: path,
        glyphWidths: const [10, 10, 10],
        letterSpacing: -2,
      );
      expect(placements[1].position.dx, closeTo(8.0, 1e-3));
      expect(placements[2].position.dx, closeTo(16.0, 1e-3));
    });

    test('startOffset shifts the whole run', () {
      final path = BezierPath.line(const Offset(0, 0), const Offset(100, 0));
      final placements = TextPathLayout.layout(
        path: path,
        glyphWidths: const [10, 10, 10],
        startOffset: 25,
      );
      expect(placements[0].position.dx, closeTo(25.0, 1e-3));
      expect(placements[1].position.dx, closeTo(35.0, 1e-3));
      expect(placements[2].position.dx, closeTo(45.0, 1e-3));
    });
  });

  group('TextPathLayout.layout — edge cases', () {
    test('empty glyph list returns empty placements', () {
      final path = BezierPath.line(const Offset(0, 0), const Offset(10, 0));
      expect(
        TextPathLayout.layout(path: path, glyphWidths: const []),
        isEmpty,
      );
    });

    test('overflow: text longer than path drops trailing glyphs', () {
      final path = BezierPath.line(const Offset(0, 0), const Offset(25, 0));
      final placements = TextPathLayout.layout(
        path: path,
        glyphWidths: const [10, 10, 10, 10], // 4×10 = 40 vs 25 path
      );
      // First two glyphs fit (0..10, 10..20). The third would land
      // at 20..30 — past the end → drop and stop.
      expect(placements, hasLength(2));
      expect(placements.map((p) => p.glyphIndex).toList(), [0, 1]);
    });

    test('exact-fit glyph at the end is still drawn', () {
      // Path length 30, three glyphs of 10 each → glyph 2 lands at
      // 20..30, exact end. Should be drawn (the helper has a 1e-6
      // slack for floating-point near-end cases).
      final path = BezierPath.line(const Offset(0, 0), const Offset(30, 0));
      final placements = TextPathLayout.layout(
        path: path,
        glyphWidths: const [10, 10, 10],
      );
      expect(placements, hasLength(3));
    });

    test('negative width throws ArgumentError', () {
      final path = BezierPath.line(const Offset(0, 0), const Offset(50, 0));
      expect(
        () => TextPathLayout.layout(
          path: path,
          glyphWidths: const [10, -3, 10],
        ),
        throwsArgumentError,
      );
    });

    test('zero-width glyphs do not advance the cursor (combining marks)', () {
      final path = BezierPath.line(const Offset(0, 0), const Offset(50, 0));
      final placements = TextPathLayout.layout(
        path: path,
        glyphWidths: const [10, 0, 10],
      );
      expect(placements, hasLength(3));
      // Glyph index 1 (zero-width combining mark) lands at the
      // same x as glyph 0 + advance = 10. Glyph 2 also at 10.
      expect(placements[0].position.dx, closeTo(0, 1e-3));
      expect(placements[1].position.dx, closeTo(10, 1e-3));
      expect(placements[2].position.dx, closeTo(10, 1e-3));
    });

    test('startOffset past path end: nothing fits', () {
      final path = BezierPath.line(const Offset(0, 0), const Offset(50, 0));
      final placements = TextPathLayout.layout(
        path: path,
        glyphWidths: const [10],
        startOffset: 51,
      );
      expect(placements, isEmpty);
    });
  });

  group('TextPathLayout.layout — multi-segment paths', () {
    test('right-angle path: glyphs on both segments', () {
      // L-shaped: (0,0) → (50,0) horizontal, (50,0) → (50,50) vertical.
      final path = BezierPath(
        segments: [
          CubicBezier.line(const Offset(0, 0), const Offset(50, 0)),
          CubicBezier.line(const Offset(50, 0), const Offset(50, 50)),
        ],
      );
      // Three 25-wide glyphs: glyph 0 lands on horizontal at 0,
      // glyph 1 lands at horizontal-end (s=25), glyph 2 lands on
      // vertical at s=50.
      final placements = TextPathLayout.layout(
        path: path,
        glyphWidths: const [25, 25, 25, 25],
      );
      expect(placements, hasLength(4));
      // Glyph 0 + 1 horizontal — tangent ~0.
      expect(placements[0].tangentRadians, closeTo(0.0, 1e-2));
      expect(placements[1].tangentRadians, closeTo(0.0, 1e-2));
      // Glyph 2 + 3 vertical — tangent ~π/2.
      expect(placements[2].tangentRadians, closeTo(math.pi / 2, 1e-2));
      expect(placements[3].tangentRadians, closeTo(math.pi / 2, 1e-2));
    });
  });

  group('GlyphPlacement value class', () {
    test('equality + hashCode pin every field', () {
      const a = GlyphPlacement(
        position: Offset(1, 2),
        tangentRadians: 0.5,
        advance: 10,
        glyphIndex: 3,
      );
      const b = GlyphPlacement(
        position: Offset(1, 2),
        tangentRadians: 0.5,
        advance: 10,
        glyphIndex: 3,
      );
      const c = GlyphPlacement(
        position: Offset(1, 2),
        tangentRadians: 0.5,
        advance: 11,
        glyphIndex: 3,
      );
      expect(a, b);
      expect(a == c, isFalse);
      expect(a.hashCode, b.hashCode);
    });
  });

  group('PathSample value class', () {
    test('equality + hashCode pin position + tangent', () {
      const a = PathSample(position: Offset(1, 2), tangentRadians: 0.3);
      const b = PathSample(position: Offset(1, 2), tangentRadians: 0.3);
      const c = PathSample(position: Offset(1, 3), tangentRadians: 0.3);
      expect(a, b);
      expect(a == c, isFalse);
      expect(a.hashCode, b.hashCode);
    });
  });
}
