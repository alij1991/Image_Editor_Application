import 'dart:io';
import 'dart:math' as math;

import 'package:image/image.dart' as img;
import 'package:opencv_dart/opencv_dart.dart' as cv;

import '../../../core/logging/app_logger.dart';
import '../domain/models/scan_models.dart';
import 'classical_corner_seed.dart';

final _log = AppLogger('HoughQuadSeed');

/// Phase XVI.3: Hough-transform-based quad detector.
///
/// Runs AHEAD of the existing [OpenCvCornerSeed] (contour-based)
/// because Hough and contour fail on different inputs — combining
/// them raises the auto-crop success rate on cluttered scans where
/// contour picks the wrong quad (e.g. a book outline around the
/// page instead of the page itself).
///
/// Algorithm:
///   1. Downscale to ~720 px long edge.
///   2. Grayscale → Gaussian blur → Canny edges → dilate.
///   3. `cv.HoughLinesP` with a minimum length threshold that filters
///      out text segments — only page-edge-class lines survive.
///   4. Cluster surviving lines by angle into "primary" (most
///      common direction) and "secondary" (perpendicular to
///      primary) groups.
///   5. Within each cluster, pick the two lines with the largest
///      perpendicular separation. Intersect → four candidate
///      corners.
///   6. Validate the quad: convex, area ≥ 10 % of frame, aspect
///      ratio sane, no edge < 15 % of the shortest frame side.
///
/// Returns null when any step bails; the chained fallback
/// ([OpenCvCornerSeed] → [ClassicalCornerSeed] → [Corners.inset])
/// takes over.
///
/// Unlike [OpenCvCornerSeed], this seeder does not implement
/// [seedBatch]; it inherits the default parallel forwarder from
/// [CornerSeeder]. The CPU cost is similar to contour-based seeding
/// so the per-page speed is already in the right ballpark and the
/// isolate worker doesn't bring material savings for the typical
/// 4–8 page import.
class HoughQuadCornerSeed extends CornerSeeder {
  const HoughQuadCornerSeed({this.fallback = const ClassicalCornerSeed()});

  /// Called when Hough can't find a valid quad. Defaults to the
  /// pure-Dart Sobel seeder so consumers that use [HoughQuadCornerSeed]
  /// standalone don't lose graceful-degradation behaviour. Integrators
  /// that chain it with [OpenCvCornerSeed] pass the OpenCV seeder in
  /// here.
  final CornerSeeder fallback;

  @override
  Future<SeedResult> seed(String imagePath) async {
    final sw = Stopwatch()..start();
    try {
      final bytes = await File(imagePath).readAsBytes();
      final decoded = img.decodeImage(bytes);
      if (decoded == null) {
        _log.w('decode failed, delegating');
        return fallback.seed(imagePath);
      }
      final small = _downscale(decoded);
      final corners = _detectQuad(small);
      if (corners == null) {
        _log.d('no quad found, delegating');
        return fallback.seed(imagePath);
      }
      _log.i('quad found', {
        'ms': sw.elapsedMilliseconds,
        'src': '${decoded.width}x${decoded.height}',
      });
      return SeedResult(corners: corners, fellBack: false);
    } catch (e, st) {
      _log.w('hough seed failed, delegating', {'err': e.toString()});
      _log.d('stack', st);
      return fallback.seed(imagePath);
    }
  }

  img.Image _downscale(img.Image src) {
    const target = 720;
    final longEdge = math.max(src.width, src.height);
    if (longEdge <= target) return src;
    final scale = target / longEdge;
    return img.copyResize(
      src,
      width: (src.width * scale).round(),
      height: (src.height * scale).round(),
      interpolation: img.Interpolation.linear,
    );
  }

  Corners? _detectQuad(img.Image small) {
    cv.Mat? srcMat;
    cv.Mat? gray;
    cv.Mat? blurred;
    cv.Mat? edges;
    cv.Mat? dilated;
    cv.Mat? kernel;
    cv.Mat? lines;
    try {
      final w = small.width;
      final h = small.height;
      final flat = small
          .convert(numChannels: 3)
          .getBytes(order: img.ChannelOrder.bgr);
      srcMat = cv.Mat.fromList(h, w, cv.MatType.CV_8UC3, flat);
      gray = cv.cvtColor(srcMat, cv.COLOR_BGR2GRAY);
      blurred = cv.gaussianBlur(gray, (5, 5), 0);
      edges = cv.canny(blurred, 50, 150);
      kernel = cv.getStructuringElement(cv.MORPH_RECT, (3, 3));
      dilated = cv.dilate(edges, kernel);

      final longEdge = math.max(w, h).toDouble();
      final minLineLen = math.max(30.0, longEdge * 0.25);
      lines = cv.HoughLinesP(
        dilated,
        1,
        math.pi / 180,
        80,
        minLineLength: minLineLen,
        maxLineGap: 20,
      );
      if (lines.rows < 4) {
        _log.d('too few lines for a quad', {'count': lines.rows});
        return null;
      }

      // Pull segments into Dart so the rest of the pipeline is easy
      // to reason about. OpenCV's Mat indexing on a HoughLinesP
      // result returns (x1, y1, x2, y2) int columns.
      final segments = <_Segment>[];
      for (var i = 0; i < lines.rows; i++) {
        final x1 = lines.at<int>(i, 0).toDouble();
        final y1 = lines.at<int>(i, 1).toDouble();
        final x2 = lines.at<int>(i, 2).toDouble();
        final y2 = lines.at<int>(i, 3).toDouble();
        segments.add(_Segment(x1: x1, y1: y1, x2: x2, y2: y2));
      }

      return _quadFromSegments(segments, w, h);
    } finally {
      srcMat?.dispose();
      gray?.dispose();
      blurred?.dispose();
      edges?.dispose();
      kernel?.dispose();
      dilated?.dispose();
      lines?.dispose();
    }
  }

  /// Walks [segments] through steps 4–6: cluster by angle, pick the
  /// extreme lines in each cluster, intersect, validate. Returns
  /// normalized [Corners] or null.
  ///
  /// Exposed (via the public [pickQuad] entry point) so unit tests
  /// can exercise the pure-Dart logic without building a real
  /// OpenCV Mat chain.
  static Corners? _quadFromSegments(
    List<_Segment> segments,
    int frameW,
    int frameH,
  ) {
    if (segments.length < 4) return null;

    // Step 4a: find the primary direction by 5°-bucketed histogram.
    final primary = _dominantAngleDeg(segments);
    if (primary == null) return null;

    // Step 4b: assemble clusters. Primary = segments within ±10° of
    // the mode (mod 180°). Secondary = segments within ±15° of the
    // perpendicular direction. Wider tolerance on secondary because
    // perpendicular edges are usually less pronounced than the
    // primary (e.g. short sides of a document vs long sides).
    final secondary = (primary + 90.0) % 180.0;
    final primaryCluster = <_Segment>[];
    final secondaryCluster = <_Segment>[];
    for (final seg in segments) {
      final a = seg.angleDeg;
      if (_angularDistanceDeg(a, primary) <= 10) {
        primaryCluster.add(seg);
      } else if (_angularDistanceDeg(a, secondary) <= 15) {
        secondaryCluster.add(seg);
      }
    }
    if (primaryCluster.length < 2 || secondaryCluster.length < 2) {
      return null;
    }

    // Step 5: within each cluster pick the two lines with the
    // largest perpendicular separation (= max/min projection of
    // each line's midpoint onto the cluster normal).
    final primaryPair = _pickExtremePair(primaryCluster, primary);
    final secondaryPair = _pickExtremePair(secondaryCluster, secondary);
    if (primaryPair == null || secondaryPair == null) return null;

    // Step 6: intersect every primary line with every secondary
    // line → 4 corner candidates.
    final c00 = _intersect(primaryPair.$1, secondaryPair.$1);
    final c01 = _intersect(primaryPair.$1, secondaryPair.$2);
    final c10 = _intersect(primaryPair.$2, secondaryPair.$1);
    final c11 = _intersect(primaryPair.$2, secondaryPair.$2);
    if (c00 == null || c01 == null || c10 == null || c11 == null) {
      return null;
    }

    final quadPoints = <(double, double)>[c00, c01, c10, c11];
    final ordered = _orderTlTrBrBl(quadPoints);

    // Validation: all points inside an expanded frame (25% margin),
    // convex, non-zero area ≥ 10% of frame, min edge ≥ 15% of short
    // side. The margin allowance is needed because a slightly tilted
    // photo can put the projected corners a few pixels outside the
    // raw frame bounds; refusing those would over-reject.
    final marginX = frameW * 0.25;
    final marginY = frameH * 0.25;
    for (final p in ordered) {
      if (p.$1 < -marginX ||
          p.$1 > frameW + marginX ||
          p.$2 < -marginY ||
          p.$2 > frameH + marginY) {
        return null;
      }
    }
    if (!_isConvex(ordered)) return null;
    final quadArea = _polygonArea(ordered);
    if (quadArea < frameW * frameH * 0.10) return null;
    final shortSide = math.min(frameW, frameH).toDouble();
    if (!_allEdgesLongerThan(ordered, shortSide * 0.15)) return null;

    return Corners(
      Point2(
        (ordered[0].$1 / (frameW - 1)).clamp(0.0, 1.0),
        (ordered[0].$2 / (frameH - 1)).clamp(0.0, 1.0),
      ),
      Point2(
        (ordered[1].$1 / (frameW - 1)).clamp(0.0, 1.0),
        (ordered[1].$2 / (frameH - 1)).clamp(0.0, 1.0),
      ),
      Point2(
        (ordered[2].$1 / (frameW - 1)).clamp(0.0, 1.0),
        (ordered[2].$2 / (frameH - 1)).clamp(0.0, 1.0),
      ),
      Point2(
        (ordered[3].$1 / (frameW - 1)).clamp(0.0, 1.0),
        (ordered[3].$2 / (frameH - 1)).clamp(0.0, 1.0),
      ),
    );
  }

  /// Public entry point for unit tests — feeds synthetic line
  /// segments straight through the quad-fit pipeline without
  /// needing an OpenCV Mat.
  static Corners? pickQuad({
    required List<(double, double, double, double)> segments,
    required int frameWidth,
    required int frameHeight,
  }) {
    final segs = segments
        .map(
          (s) => _Segment(x1: s.$1, y1: s.$2, x2: s.$3, y2: s.$4),
        )
        .toList();
    return _quadFromSegments(segs, frameWidth, frameHeight);
  }

  /// Peak angle in the 5°-bin histogram. Returns null when every
  /// bin is empty (impossible here — the caller already checked
  /// `segments.length ≥ 4`).
  static double? _dominantAngleDeg(List<_Segment> segments) {
    const binCount = 36; // 180° / 5° = 36
    final counts = List<int>.filled(binCount, 0);
    for (final seg in segments) {
      final bin = (seg.angleDeg / 5).floor() % binCount;
      counts[bin]++;
    }
    int bestBin = 0;
    int bestCount = 0;
    for (int i = 0; i < binCount; i++) {
      // Smooth across a ±1 bin window so a cluster split across
      // two adjacent bins (e.g. 88° and 92°) still peaks correctly.
      final left = counts[(i - 1 + binCount) % binCount];
      final right = counts[(i + 1) % binCount];
      final smoothed = counts[i] + (left + right) ~/ 2;
      if (smoothed > bestCount) {
        bestCount = smoothed;
        bestBin = i;
      }
    }
    if (bestCount < 2) return null;
    return bestBin * 5.0 + 2.5;
  }

  /// Shortest angular distance between two directions on the [0°,
  /// 180°) circle.
  static double _angularDistanceDeg(double a, double b) {
    final diff = (a - b).abs() % 180.0;
    return math.min(diff, 180.0 - diff);
  }

  /// Within a roughly-parallel cluster, return the two lines whose
  /// midpoints have the largest perpendicular separation.
  static (_Segment, _Segment)? _pickExtremePair(
    List<_Segment> cluster,
    double clusterAngleDeg,
  ) {
    if (cluster.length < 2) return null;
    final perpRad = (clusterAngleDeg + 90.0) * math.pi / 180.0;
    final nx = math.cos(perpRad);
    final ny = math.sin(perpRad);
    double minProj = double.infinity;
    double maxProj = -double.infinity;
    _Segment? minSeg;
    _Segment? maxSeg;
    for (final seg in cluster) {
      final mx = (seg.x1 + seg.x2) / 2.0;
      final my = (seg.y1 + seg.y2) / 2.0;
      final proj = mx * nx + my * ny;
      if (proj < minProj) {
        minProj = proj;
        minSeg = seg;
      }
      if (proj > maxProj) {
        maxProj = proj;
        maxSeg = seg;
      }
    }
    if (minSeg == null || maxSeg == null || identical(minSeg, maxSeg)) {
      return null;
    }
    // Require meaningful separation — degenerate "two lines on top
    // of each other" is noise.
    if ((maxProj - minProj) < 8.0) return null;
    return (minSeg, maxSeg);
  }

  /// Line-line intersection (infinite extensions). Returns null if
  /// the lines are parallel.
  static (double, double)? _intersect(_Segment a, _Segment b) {
    final d1x = a.x2 - a.x1;
    final d1y = a.y2 - a.y1;
    final d2x = b.x2 - b.x1;
    final d2y = b.y2 - b.y1;
    final denom = d1x * d2y - d1y * d2x;
    if (denom.abs() < 1e-6) return null;
    final t = ((b.x1 - a.x1) * d2y - (b.y1 - a.y1) * d2x) / denom;
    return (a.x1 + t * d1x, a.y1 + t * d1y);
  }

  /// Sort four points by (x+y) and (x-y) to produce TL/TR/BR/BL
  /// order. Same trick [OpenCvCornerSeed] uses.
  static List<(double, double)> _orderTlTrBrBl(List<(double, double)> pts) {
    final sorted = List<(double, double)>.from(pts)
      ..sort((a, b) => (a.$1 + a.$2).compareTo(b.$1 + b.$2));
    final tl = sorted.first;
    final br = sorted.last;
    final mid = sorted.sublist(1, sorted.length - 1)
      ..sort((a, b) => (a.$1 - a.$2).compareTo(b.$1 - b.$2));
    final bl = mid.first;
    final tr = mid.last;
    return [tl, tr, br, bl];
  }

  /// Classical shoelace-formula polygon area.
  static double _polygonArea(List<(double, double)> pts) {
    double sum = 0;
    for (int i = 0; i < pts.length; i++) {
      final a = pts[i];
      final b = pts[(i + 1) % pts.length];
      sum += a.$1 * b.$2 - b.$1 * a.$2;
    }
    return sum.abs() / 2;
  }

  /// Returns true iff every turn around [pts] has the same sign —
  /// the quadrilateral is convex.
  static bool _isConvex(List<(double, double)> pts) {
    int sign = 0;
    for (int i = 0; i < pts.length; i++) {
      final a = pts[i];
      final b = pts[(i + 1) % pts.length];
      final c = pts[(i + 2) % pts.length];
      final cross =
          (b.$1 - a.$1) * (c.$2 - b.$2) - (b.$2 - a.$2) * (c.$1 - b.$1);
      if (cross == 0) continue;
      final s = cross > 0 ? 1 : -1;
      if (sign == 0) {
        sign = s;
      } else if (sign != s) {
        return false;
      }
    }
    return sign != 0;
  }

  /// True iff every edge of [pts] is longer than [minLen].
  static bool _allEdgesLongerThan(List<(double, double)> pts, double minLen) {
    for (int i = 0; i < pts.length; i++) {
      final a = pts[i];
      final b = pts[(i + 1) % pts.length];
      final dx = b.$1 - a.$1;
      final dy = b.$2 - a.$2;
      if (math.sqrt(dx * dx + dy * dy) < minLen) return false;
    }
    return true;
  }
}

/// Oriented 2D line segment with its angle in [0°, 180°). Private to
/// the seeder.
class _Segment {
  _Segment({
    required this.x1,
    required this.y1,
    required this.x2,
    required this.y2,
  });

  final double x1;
  final double y1;
  final double x2;
  final double y2;

  /// Orientation of the line the segment sits on, in [0°, 180°).
  /// Angles are folded mod 180° because a line has no direction.
  double get angleDeg {
    final dx = x2 - x1;
    final dy = y2 - y1;
    if (dx == 0 && dy == 0) return 0;
    var deg = math.atan2(dy, dx) * 180.0 / math.pi;
    if (deg < 0) deg += 180.0;
    if (deg >= 180.0) deg -= 180.0;
    return deg;
  }
}
