import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';

import 'package:image_editor/engine/geometry/guided_upright.dart';

void main() {
  group('GuidedUprightLine', () {
    test('isHorizontal heuristic groups by larger axis delta', () {
      const h = GuidedUprightLine(x1: 0, y1: 0.5, x2: 1, y2: 0.55);
      const v = GuidedUprightLine(x1: 0.5, y1: 0, x2: 0.55, y2: 1);
      expect(h.isHorizontal, isTrue);
      expect(v.isHorizontal, isFalse);
    });

    test('homogeneous representation is satisfied by both endpoints', () {
      const l = GuidedUprightLine(x1: 0.2, y1: 0.4, x2: 0.8, y2: 0.6);
      final h = l.homogeneous;
      final r1 = h[0] * l.x1 + h[1] * l.y1 + h[2];
      final r2 = h[0] * l.x2 + h[1] * l.y2 + h[2];
      expect(r1.abs(), lessThan(1e-9));
      expect(r2.abs(), lessThan(1e-9));
    });

    test('codec round-trips quad form', () {
      const l = GuidedUprightLine(x1: 0.1, y1: 0.2, x2: 0.7, y2: 0.85);
      final encoded = GuidedUprightLineCodec.encode([l]);
      final decoded = GuidedUprightLineCodec.decode(encoded);
      expect(decoded.length, 1);
      expect(decoded.first, l);
    });

    test('codec drops malformed quads silently', () {
      final raw = [
        [0.1, 0.2, 0.3, 0.4], // valid
        [1, 2, 3], // too short
        'wrong', // wrong type
        [0.0, 0.0, 0.0, 0.0], // degenerate (coincident)
        [double.nan, 0, 1, 1], // non-finite
      ];
      final decoded = GuidedUprightLineCodec.decode(raw);
      expect(decoded, hasLength(1));
      expect(decoded.first.x1, 0.1);
    });

    test('codec handles non-list payloads', () {
      expect(GuidedUprightLineCodec.decode(null), isEmpty);
      expect(GuidedUprightLineCodec.decode('not a list'), isEmpty);
      expect(GuidedUprightLineCodec.decode(42), isEmpty);
    });
  });

  group('invert3x3', () {
    test('identity inverts to itself', () {
      final inv = invert3x3([1, 0, 0, 0, 1, 0, 0, 0, 1])!;
      for (var i = 0; i < 9; i++) {
        final expected = (i == 0 || i == 4 || i == 8) ? 1.0 : 0.0;
        expect(inv[i], closeTo(expected, 1e-9));
      }
    });

    test('inverse times original is identity', () {
      // A non-trivial homography.
      const m = [1.05, 0.02, 0.03, -0.01, 0.95, 0.02, 0.05, 0.04, 1.0];
      final inv = invert3x3(m)!;
      // Multiply m · inv and verify == I.
      final r = _multiply(m, inv);
      for (var i = 0; i < 9; i++) {
        final expected = (i == 0 || i == 4 || i == 8) ? 1.0 : 0.0;
        expect(r[i], closeTo(expected, 1e-9));
      }
    });

    test('singular matrix returns null', () {
      // All zeros (det = 0).
      final inv = invert3x3([0, 0, 0, 0, 0, 0, 0, 0, 0]);
      expect(inv, isNull);
    });
  });

  group('GuidedUprightSolver', () {
    test('zero or one line returns identity', () {
      expect(GuidedUprightSolver.solve(const []), GuidedUprightSolver.identity);
      expect(
        GuidedUprightSolver.solve(const [
          GuidedUprightLine(x1: 0.1, y1: 0.5, x2: 0.9, y2: 0.5),
        ]),
        GuidedUprightSolver.identity,
      );
    });

    test('two perfectly horizontal lines yield identity (no skew to fix)', () {
      final h = GuidedUprightSolver.solve(const [
        GuidedUprightLine(x1: 0.1, y1: 0.30, x2: 0.9, y2: 0.30),
        GuidedUprightLine(x1: 0.1, y1: 0.70, x2: 0.9, y2: 0.70),
      ]);
      // Lines are parallel → vanishing point at infinity → no
      // perspective correction needed; the rotation fallback reads
      // 0° too because both lines are already horizontal.
      _expectMatrixApprox(h, GuidedUprightSolver.identity, 1e-6);
    });

    test('horizontal lines that converge to the right map to a point at infinity in x', () {
      // Two lines that intersect well off-frame to the right form a
      // horizontal vanishing point. After the homography their
      // post-warp y-coords should match per line.
      const lines = [
        GuidedUprightLine(x1: 0.10, y1: 0.30, x2: 0.90, y2: 0.34),
        GuidedUprightLine(x1: 0.10, y1: 0.70, x2: 0.90, y2: 0.66),
      ];
      final h = GuidedUprightSolver.solve(lines);
      // Verify each line is horizontal in the warped output.
      for (final l in lines) {
        final p1 = _apply(h, l.x1, l.y1);
        final p2 = _apply(h, l.x2, l.y2);
        expect((p1.$2 - p2.$2).abs(), lessThan(1e-3),
            reason: 'line ${l.toQuad()} not horizontal after warp');
      }
    });

    test('two converging vertical lines map to a point at infinity in y', () {
      const lines = [
        GuidedUprightLine(x1: 0.30, y1: 0.10, x2: 0.34, y2: 0.90),
        GuidedUprightLine(x1: 0.70, y1: 0.10, x2: 0.66, y2: 0.90),
      ];
      final h = GuidedUprightSolver.solve(lines);
      for (final l in lines) {
        final p1 = _apply(h, l.x1, l.y1);
        final p2 = _apply(h, l.x2, l.y2);
        expect((p1.$1 - p2.$1).abs(), lessThan(1e-3),
            reason: 'line ${l.toQuad()} not vertical after warp');
      }
    });

    test('full 4-guide solve aligns both axes', () {
      // Classic keystone correction: a building photographed from
      // street level with the camera tilted up. 2 H-lines on the
      // façade converge to the right; 2 V-lines on the windows
      // converge upward.
      const lines = [
        GuidedUprightLine(x1: 0.10, y1: 0.30, x2: 0.90, y2: 0.34),
        GuidedUprightLine(x1: 0.10, y1: 0.70, x2: 0.90, y2: 0.66),
        GuidedUprightLine(x1: 0.30, y1: 0.10, x2: 0.32, y2: 0.90),
        GuidedUprightLine(x1: 0.70, y1: 0.10, x2: 0.68, y2: 0.90),
      ];
      final h = GuidedUprightSolver.solve(lines);
      // Both H-lines should be horizontal post-warp.
      for (final l in lines.where((l) => l.isHorizontal)) {
        final p1 = _apply(h, l.x1, l.y1);
        final p2 = _apply(h, l.x2, l.y2);
        expect((p1.$2 - p2.$2).abs(), lessThan(1e-3),
            reason: 'H-line not horizontal');
      }
      // Both V-lines should be vertical post-warp.
      for (final l in lines.where((l) => !l.isHorizontal)) {
        final p1 = _apply(h, l.x1, l.y1);
        final p2 = _apply(h, l.x2, l.y2);
        expect((p1.$1 - p2.$1).abs(), lessThan(1e-3),
            reason: 'V-line not vertical');
      }
    });

    test('rotation-only fallback fires for 1H + 1V tilted input', () {
      // Single horizontal + single vertical line, both tilted by
      // 5° CCW (camera tilted CCW around its optical axis). Since
      // neither group has 2 lines, no vanishing point exists; the
      // solver should return a pure rotation that averages the two
      // residual angles. Both contribute the same sign in this
      // setup, so the rotation effectively undoes the tilt.
      const tiltDeg = 5.0;
      const tiltRad = tiltDeg * math.pi / 180;
      final c = math.cos(tiltRad);
      final s = math.sin(tiltRad);
      // Forward CCW-around-(0.5,0.5) of the canonical horizontal
      // line (0.1,0.5)→(0.9,0.5). Right end goes up (smaller y).
      final hLine = GuidedUprightLine(
        x1: 0.5 + (-0.4) * c + 0.0 * s,
        y1: 0.5 + (-0.4) * (-s) + 0.0 * c,
        x2: 0.5 + 0.4 * c + 0.0 * s,
        y2: 0.5 + 0.4 * (-s) + 0.0 * c,
      );
      // Same forward CCW rotation of the canonical vertical line
      // (0.5,0.1)→(0.5,0.9). Top end shifts left, bottom shifts
      // right — the v-line tilts in the same rotational sense.
      final vLine = GuidedUprightLine(
        x1: 0.5 + 0.0 * c + (-0.4) * s,
        y1: 0.5 + 0.0 * (-s) + (-0.4) * c,
        x2: 0.5 + 0.0 * c + 0.4 * s,
        y2: 0.5 + 0.0 * (-s) + 0.4 * c,
      );
      final h = GuidedUprightSolver.solve([hLine, vLine]);
      // After rotation, the H-line should be ~horizontal.
      final p1 = _apply(h, hLine.x1, hLine.y1);
      final p2 = _apply(h, hLine.x2, hLine.y2);
      expect((p1.$2 - p2.$2).abs(), lessThan(0.01),
          reason: 'H-line not horizontal after rotation: '
              '${p1.$2} vs ${p2.$2}');
      // And the V-line should be ~vertical.
      final v1 = _apply(h, vLine.x1, vLine.y1);
      final v2 = _apply(h, vLine.x2, vLine.y2);
      expect((v1.$1 - v2.$1).abs(), lessThan(0.01),
          reason: 'V-line not vertical after rotation: '
              '${v1.$1} vs ${v2.$1}');
    });

    test('image centre maps to (0.5, 0.5) after solve', () {
      // The centring step keeps the image content from drifting
      // off-frame on strong corrections.
      const lines = [
        GuidedUprightLine(x1: 0.10, y1: 0.20, x2: 0.90, y2: 0.30),
        GuidedUprightLine(x1: 0.10, y1: 0.80, x2: 0.90, y2: 0.70),
      ];
      final h = GuidedUprightSolver.solve(lines);
      final c = _apply(h, 0.5, 0.5);
      expect(c.$1, closeTo(0.5, 1e-3));
      expect(c.$2, closeTo(0.5, 1e-3));
    });

    test('solve never returns NaN or Inf', () {
      // Adversarial: lines that nearly coincide or are nearly
      // parallel on the same y. The solver should still produce a
      // finite matrix (typically identity).
      const lines = [
        GuidedUprightLine(x1: 0.1, y1: 0.5, x2: 0.9, y2: 0.5),
        GuidedUprightLine(x1: 0.1, y1: 0.5001, x2: 0.9, y2: 0.5001),
      ];
      final h = GuidedUprightSolver.solve(lines);
      for (final v in h) {
        expect(v.isFinite, isTrue, reason: 'matrix has non-finite entry: $h');
      }
    });

    test('matrix passed back is invertible (so the pass builder can use it)', () {
      const lines = [
        GuidedUprightLine(x1: 0.10, y1: 0.30, x2: 0.90, y2: 0.34),
        GuidedUprightLine(x1: 0.10, y1: 0.70, x2: 0.90, y2: 0.66),
      ];
      final h = GuidedUprightSolver.solve(lines);
      final inv = invert3x3(h);
      expect(inv, isNotNull);
    });
  });
}

/// Apply a 3×3 row-major homography to a 2D point, returning the
/// projected 2D point.
(double, double) _apply(List<double> m, double x, double y) {
  final px = m[0] * x + m[1] * y + m[2];
  final py = m[3] * x + m[4] * y + m[5];
  final pw = m[6] * x + m[7] * y + m[8];
  return (px / pw, py / pw);
}

List<double> _multiply(List<double> a, List<double> b) {
  final r = List<double>.filled(9, 0);
  for (var i = 0; i < 3; i++) {
    for (var j = 0; j < 3; j++) {
      var s = 0.0;
      for (var k = 0; k < 3; k++) {
        s += a[i * 3 + k] * b[k * 3 + j];
      }
      r[i * 3 + j] = s;
    }
  }
  return r;
}

void _expectMatrixApprox(
  List<double> actual,
  List<double> expected,
  double tol,
) {
  for (var i = 0; i < 9; i++) {
    expect(actual[i], closeTo(expected[i], tol),
        reason: 'matrix entry $i differs');
  }
}
