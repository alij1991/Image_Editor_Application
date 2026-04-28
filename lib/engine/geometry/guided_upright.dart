import 'dart:math' as math;

/// XVI.45 — Guided Upright perspective.
///
/// User draws 2-4 line segments on the image that should be parallel
/// to the horizontal or vertical axis after correction. The solver
/// produces a 3×3 homography that pushes the implied vanishing
/// points to infinity, undoing keystone distortion.
///
/// The math follows the standard two-vanishing-point formulation:
///
///   1. Group input lines by orientation: a line is "horizontal" iff
///      |dx| ≥ |dy|, otherwise "vertical".
///   2. For each group with ≥ 2 lines, compute the vanishing point as
///      the (sign-normalised, magnitude-normalised) mean of pairwise
///      cross-product intersections. A single line in a group
///      contributes nothing — the corresponding axis falls back to
///      "no perspective correction in this direction".
///   3. Build the homography
///        W = [[1, 0, c],
///             [0, 1, f],
///             [g, h, 1]]
///      with c, f, g, h chosen so W·V_h ∝ (1, 0, 0) and
///      W·V_v ∝ (0, 1, 0). When only one vanishing point is
///      available the missing-direction terms collapse to identity.
///   4. Post-multiply by a translation that brings the image centre
///      back to (0.5, 0.5) — the projective change moves it
///      otherwise.
///
/// The returned matrix is the *source → dest* mapping in row-major
/// order (9 doubles). The shader at `shaders/perspective_warp.frag`
/// expects *dest → source* (inverse-warp sampling); the caller must
/// invert via [invert3x3] before uploading.
///
/// All coordinates are in normalised [0, 1] image space, matching the
/// shader's `FlutterFragCoord / u_size` convention. The solver makes
/// no assumption about the image's pixel dimensions, so the same op
/// renders identically at every resolution.
class GuidedUprightLine {
  const GuidedUprightLine({
    required this.x1,
    required this.y1,
    required this.x2,
    required this.y2,
  });

  final double x1;
  final double y1;
  final double x2;
  final double y2;

  /// Heuristic orientation. Lines closer to horizontal are grouped
  /// into the "should be horizontal" bucket; the rest go into the
  /// vertical bucket.
  bool get isHorizontal => (x2 - x1).abs() >= (y2 - y1).abs();

  /// Length in normalised units. Used to weight the line in the
  /// solver — longer lines are more reliable orientation signals.
  double get length =>
      math.sqrt((x2 - x1) * (x2 - x1) + (y2 - y1) * (y2 - y1));

  /// Homogeneous line representation `[a, b, c]` such that
  /// `a·x + b·y + c = 0` is satisfied by both endpoints. Computed as
  /// the cross product of the two homogeneous endpoints.
  List<double> get homogeneous {
    // p1 × p2 with p_i = (x_i, y_i, 1)
    return [
      y1 - y2,
      x2 - x1,
      x1 * y2 - x2 * y1,
    ];
  }

  /// Round-trip storage form. The pipeline persists guides as
  /// `[x1, y1, x2, y2]` quads, see [GuidedUprightLineCodec].
  List<double> toQuad() => [x1, y1, x2, y2];

  static GuidedUprightLine? fromQuad(Object? raw) {
    if (raw is! List || raw.length < 4) return null;
    double? coord(int i) {
      final v = raw[i];
      return v is num ? v.toDouble() : null;
    }

    final x1 = coord(0);
    final y1 = coord(1);
    final x2 = coord(2);
    final y2 = coord(3);
    if (x1 == null || y1 == null || x2 == null || y2 == null) {
      return null;
    }
    if (!x1.isFinite || !y1.isFinite || !x2.isFinite || !y2.isFinite) {
      return null;
    }
    if ((x1 - x2).abs() < 1e-6 && (y1 - y2).abs() < 1e-6) {
      // Degenerate — both endpoints coincide.
      return null;
    }
    return GuidedUprightLine(x1: x1, y1: y1, x2: x2, y2: y2);
  }

  @override
  bool operator ==(Object other) =>
      other is GuidedUprightLine &&
      other.x1 == x1 &&
      other.y1 == y1 &&
      other.x2 == x2 &&
      other.y2 == y2;

  @override
  int get hashCode => Object.hash(x1, y1, x2, y2);
}

/// Codec for the `lines` parameter on the guided-upright op.
///
/// The op stores `parameters['lines'] = List<List<double>>` where each
/// inner list is `[x1, y1, x2, y2]`. The codec is a pure-Dart
/// converter — no runtime I/O — so both the renderer and the
/// solver-test can call it without booting any Flutter machinery.
class GuidedUprightLineCodec {
  GuidedUprightLineCodec._();

  /// Convert the raw `lines` parameter to a typed list. Malformed
  /// entries are skipped silently (round-trip safety: a forward-
  /// compat field can survive without breaking the renderer).
  static List<GuidedUprightLine> decode(Object? raw) {
    if (raw is! List) return const [];
    final out = <GuidedUprightLine>[];
    for (final entry in raw) {
      final line = GuidedUprightLine.fromQuad(entry);
      if (line != null) out.add(line);
    }
    return out;
  }

  /// Encode for storage in the op's parameter map. Returns a fresh
  /// `List<List<double>>` so the caller can mutate without affecting
  /// the source guides.
  static List<List<double>> encode(List<GuidedUprightLine> lines) {
    return [for (final l in lines) l.toQuad()];
  }
}

/// Solver for the Guided Upright homography.
///
/// Static-only — the solver holds no state and returns a fresh matrix
/// per call. The 3×3 result is row-major with 9 entries.
class GuidedUprightSolver {
  GuidedUprightSolver._();

  /// 3×3 row-major identity. The renderer treats this as a no-op pass
  /// (samples at `uv` directly) so callers can return it whenever the
  /// solve is degenerate or ill-conditioned.
  static const List<double> identity = [
    1, 0, 0, //
    0, 1, 0, //
    0, 0, 1, //
  ];

  /// Solve for the source-to-dest homography that aligns user guides
  /// with the principal axes. Returns [identity] when fewer than 2
  /// lines are provided or every group is too small to define a
  /// vanishing point AND the lines aren't already at the axes.
  ///
  /// Output is **source → dest**. The renderer needs **dest → source**
  /// for inverse-warp sampling; caller must apply [invert3x3].
  static List<double> solve(List<GuidedUprightLine> lines) {
    if (lines.length < 2) return identity;

    final hLines = <GuidedUprightLine>[];
    final vLines = <GuidedUprightLine>[];
    for (final l in lines) {
      if (l.isHorizontal) {
        hLines.add(l);
      } else {
        vLines.add(l);
      }
    }

    final vh = _vanishingPoint(hLines);
    final vv = _vanishingPoint(vLines);

    // Single-line per group: try a pure rotation that aligns that
    // line with the axis. Keystone is left at identity.
    if (vh == null && vv == null) {
      // 1 H + 1 V (or fewer): rotate by the average residual angle.
      final angle = _averageResidualAngle(lines);
      if (angle.abs() < 1e-4) return identity;
      return _rotationAroundCentre(angle);
    }

    // Build [[1, 0, c], [0, 1, f], [g, h, 1]] with c, f, g, h from
    // the vanishing-point constraints. Missing terms collapse to 0.
    double c = 0;
    double f = 0;
    double g = 0;
    double h = 0;

    if (vh != null) {
      // W · V_h ∝ (1, 0, 0):
      //   row 1 unconstrained when c is computed from V_v alone
      //   row 2: vh.y + f·vh.w = 0 → f = -vh.y / vh.w
      //   row 3: g·vh.x + h·vh.y + vh.w = 0
      // V_h.w may be ~0 when the lines are already parallel —
      // in that case f → 0 and the row-3 constraint becomes
      // g·vh.x + h·vh.y = 0 (a direction constraint).
      if (vh[2].abs() > 1e-6) {
        f = -vh[1] / vh[2];
      }
    }
    if (vv != null) {
      // W · V_v ∝ (0, 1, 0):
      //   row 1: vv.x + c·vv.w = 0 → c = -vv.x / vv.w
      //   row 2 unconstrained when f is computed from V_h
      //   row 3: g·vv.x + h·vv.y + vv.w = 0
      if (vv[2].abs() > 1e-6) {
        c = -vv[0] / vv[2];
      }
    }

    // Solve the 2×2 linear system in (g, h):
    //   vh.x · g + vh.y · h = -vh.w
    //   vv.x · g + vv.y · h = -vv.w
    // When only one constraint is active (one vanishing point), pin
    // the missing axis to 0 and solve the residual scalar equation.
    if (vh != null && vv != null) {
      final det = vh[0] * vv[1] - vh[1] * vv[0];
      if (det.abs() < 1e-9) {
        // Vanishing points lie on the same ray from the origin —
        // ill-conditioned. Fall back to rotation-only.
        final angle = _averageResidualAngle(lines);
        if (angle.abs() < 1e-4) return identity;
        return _rotationAroundCentre(angle);
      }
      g = (-vh[2] * vv[1] + vv[2] * vh[1]) / det;
      h = (-vv[2] * vh[0] + vh[2] * vv[0]) / det;
    } else if (vh != null) {
      // Only horizontal vanishing point — pick h such that
      // g·vh.x + h·vh.y = -vh.w with g unconstrained. Set h = 0 and
      // solve for g; if vh.x is near zero, swap to h.
      if (vh[0].abs() >= vh[1].abs() && vh[0].abs() > 1e-6) {
        g = -vh[2] / vh[0];
      } else if (vh[1].abs() > 1e-6) {
        h = -vh[2] / vh[1];
      }
    } else if (vv != null) {
      if (vv[1].abs() >= vv[0].abs() && vv[1].abs() > 1e-6) {
        h = -vv[2] / vv[1];
      } else if (vv[0].abs() > 1e-6) {
        g = -vv[2] / vv[0];
      }
    }

    final w = <double>[
      1, 0, c, //
      0, 1, f, //
      g, h, 1, //
    ];

    // Re-centre so the image centre maps to (0.5, 0.5). The
    // perspective term g·x + h·y + 1 changes the projection of the
    // centre noticeably; without this step the visible content shifts
    // off-frame on strong corrections.
    final centred = _centre(w);
    if (!_isFinite(centred)) return identity;

    return centred;
  }

  /// Vanishing point of a group of lines, in homogeneous coords. Each
  /// pair of lines defines an intersection (cross product); we
  /// average across all pairs after sign-normalisation. Returns null
  /// when the group has fewer than two lines.
  ///
  /// Length-weighted: a 0.6-long guide carries more weight than a
  /// 0.05-long one because the latter's angle is dominated by sub-
  /// pixel jitter.
  static List<double>? _vanishingPoint(List<GuidedUprightLine> group) {
    if (group.length < 2) return null;
    var sx = 0.0;
    var sy = 0.0;
    var sw = 0.0;
    var weightSum = 0.0;
    for (var i = 0; i < group.length; i++) {
      for (var j = i + 1; j < group.length; j++) {
        final l1 = group[i].homogeneous;
        final l2 = group[j].homogeneous;
        var vx = l1[1] * l2[2] - l1[2] * l2[1];
        var vy = l1[2] * l2[0] - l1[0] * l2[2];
        var vw = l1[0] * l2[1] - l1[1] * l2[0];
        final mag = math.sqrt(vx * vx + vy * vy + vw * vw);
        if (mag < 1e-9) continue;
        vx /= mag;
        vy /= mag;
        vw /= mag;
        // Sign-normalise: cross products carry an arbitrary sign, but
        // a 3-vector and its negation represent the same projective
        // point. Pin to "positive w" when w is non-zero, else "first
        // non-zero component positive". Without this the sum across
        // pair intersections cancels.
        if (vw.abs() > 1e-6) {
          if (vw < 0) {
            vx = -vx;
            vy = -vy;
            vw = -vw;
          }
        } else if (vx.abs() > vy.abs()) {
          if (vx < 0) {
            vx = -vx;
            vy = -vy;
            vw = -vw;
          }
        } else if (vy < 0) {
          vx = -vx;
          vy = -vy;
          vw = -vw;
        }
        final weight = group[i].length * group[j].length;
        sx += vx * weight;
        sy += vy * weight;
        sw += vw * weight;
        weightSum += weight;
      }
    }
    if (weightSum < 1e-9) return null;
    return [sx / weightSum, sy / weightSum, sw / weightSum];
  }

  /// Mean residual angle of the input lines vs their target axis,
  /// in radians. Used as the rotation fallback when the vanishing-
  /// point system is degenerate (e.g. 1 H + 1 V line).
  static double _averageResidualAngle(List<GuidedUprightLine> lines) {
    var sum = 0.0;
    var weight = 0.0;
    for (final l in lines) {
      final dx = l.x2 - l.x1;
      final dy = l.y2 - l.y1;
      // Signed angle to nearest axis.
      var ang = math.atan2(dy, dx);
      if (l.isHorizontal) {
        // Wrap into [-π/2, π/2].
        if (ang > math.pi / 2) ang -= math.pi;
        if (ang < -math.pi / 2) ang += math.pi;
      } else {
        // Vertical reference is y-axis (π/2). Subtract.
        ang -= math.pi / 2;
        if (ang > math.pi / 2) ang -= math.pi;
        if (ang < -math.pi / 2) ang += math.pi;
      }
      final w = l.length;
      sum += ang * w;
      weight += w;
    }
    if (weight < 1e-9) return 0;
    return sum / weight;
  }

  /// Pure rotation by [angle] radians around (0.5, 0.5).
  static List<double> _rotationAroundCentre(double angle) {
    // We rotate the image *to* upright, so apply -angle.
    final c = math.cos(-angle);
    final s = math.sin(-angle);
    // Rotation around (cx, cy) = T(cx, cy) · R · T(-cx, -cy)
    const cx = 0.5;
    const cy = 0.5;
    final tx = cx - c * cx + s * cy;
    final ty = cy - s * cx - c * cy;
    return [
      c, -s, tx, //
      s, c, ty, //
      0, 0, 1, //
    ];
  }

  /// Translate [w] so its action on the image centre is identity.
  /// Without this the perspective term moves the centre off-screen
  /// for strong vanishing points.
  static List<double> _centre(List<double> w) {
    // current = w · (0.5, 0.5, 1)
    final cxN =
        w[0] * 0.5 + w[1] * 0.5 + w[2] * 1.0;
    final cyN =
        w[3] * 0.5 + w[4] * 0.5 + w[5] * 1.0;
    final wN =
        w[6] * 0.5 + w[7] * 0.5 + w[8] * 1.0;
    if (wN.abs() < 1e-9) return w;
    final curX = cxN / wN;
    final curY = cyN / wN;
    final dx = 0.5 - curX;
    final dy = 0.5 - curY;
    // T = [[1, 0, dx], [0, 1, dy], [0, 0, 1]]
    // new_w = T · w
    return [
      w[0] + dx * w[6], w[1] + dx * w[7], w[2] + dx * w[8],
      w[3] + dy * w[6], w[4] + dy * w[7], w[5] + dy * w[8],
      w[6], w[7], w[8],
    ];
  }

  static bool _isFinite(List<double> m) {
    for (final v in m) {
      if (!v.isFinite) return false;
    }
    return true;
  }
}

/// In-place 3×3 inverse for the 9-element row-major matrix the
/// solver produces. Returns null if the matrix is singular.
///
/// Used by the perspective pass builder: the solver returns
/// source→dest, the shader wants dest→source.
List<double>? invert3x3(List<double> m) {
  // Cofactor expansion. Written out long-hand because the matrix is
  // tiny and avoids the dependency on package:vector_math.
  final a = m[0], b = m[1], c = m[2];
  final d = m[3], e = m[4], f = m[5];
  final g = m[6], h = m[7], i = m[8];
  final det =
      a * (e * i - f * h) - b * (d * i - f * g) + c * (d * h - e * g);
  if (det.abs() < 1e-12) return null;
  final inv = 1.0 / det;
  return [
    (e * i - f * h) * inv,
    (c * h - b * i) * inv,
    (b * f - c * e) * inv,
    (f * g - d * i) * inv,
    (a * i - c * g) * inv,
    (c * d - a * f) * inv,
    (d * h - e * g) * inv,
    (b * g - a * h) * inv,
    (a * e - b * d) * inv,
  ];
}
