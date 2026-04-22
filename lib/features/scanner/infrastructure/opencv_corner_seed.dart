import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart' show compute;
import 'package:image/image.dart' as img;
import 'package:opencv_dart/opencv_dart.dart' as cv;

import '../../../core/logging/app_logger.dart';
import '../domain/models/scan_models.dart';
import 'classical_corner_seed.dart';

final _log = AppLogger('OpenCvSeed');

/// OpenCV-backed quad detector — a strict upgrade over the pure-Dart
/// Sobel + bounding-box heuristic.
///
/// Strategy:
///   1. Decode + grayscale + downscale the source.
///   2. Gaussian blur to suppress paper texture.
///   3. Canny edges; dilate slightly to close small breaks in the
///      page border that would otherwise split a single contour.
///   4. `cv.findContours` (RETR_LIST + CHAIN_APPROX_SIMPLE).
///   5. For each contour with area >= 10 % of the frame, run
///      `cv.approxPolyDP` with epsilon = 2 % of the perimeter and
///      keep only the ones that approximate to four convex points.
///   6. Pick the largest such quad and return it as a [Corners].
///
/// Falls back to the [ClassicalCornerSeed] (Sobel) when no quad
/// survives — same return contract, so callers don't need to know
/// which backend produced the result. The Sobel path itself falls
/// back to an inset rectangle as a last resort.
class OpenCvCornerSeed implements CornerSeeder {
  const OpenCvCornerSeed({this.fallback = const ClassicalCornerSeed()});

  final CornerSeeder fallback;

  @override
  Future<SeedResult> seed(String imagePath) async {
    final sw = Stopwatch()..start();
    try {
      final bytes = await File(imagePath).readAsBytes();
      final decoded = img.decodeImage(bytes);
      if (decoded == null) {
        _log.w('decode failed, delegating to Sobel');
        return fallback.seed(imagePath);
      }

      final small = _downscale(decoded);
      final corners = _detectQuad(small);
      if (corners == null) {
        _log.d('no quad found, delegating to Sobel');
        return fallback.seed(imagePath);
      }
      _log.i('quad found', {
        'ms': sw.elapsedMilliseconds,
        'src': '${decoded.width}x${decoded.height}',
      });
      return SeedResult(corners: corners, fellBack: false);
    } catch (e, st) {
      _log.w('opencv seed failed, delegating', {'err': e.toString()});
      _log.d('stack', st);
      return fallback.seed(imagePath);
    }
  }

  /// Phase V.9: batch-seed the whole multi-page import in a single
  /// `compute()` worker isolate — keeps the OpenCV state + FFI
  /// handles warm across pages so an 8-page gallery import pays
  /// one isolate spawn instead of eight. Main-isolate fallback
  /// (`ClassicalCornerSeed`) still runs for any page the worker
  /// couldn't resolve, preserving the pre-V.9 result contract.
  ///
  /// Short-circuits for 0 and 1-path batches:
  ///   - Empty input → empty output, no isolate spawn.
  ///   - Single path → route through [seed] directly; the
  ///     single-call isolate spawn would be pure overhead.
  @override
  Future<List<SeedResult>> seedBatch(List<String> imagePaths) async {
    if (imagePaths.isEmpty) return const [];
    if (imagePaths.length == 1) {
      return [await seed(imagePaths.first)];
    }
    final sw = Stopwatch()..start();
    // Deliberately pass a copy so the worker's mutations (if any)
    // can't leak back into the caller's list.
    final paths = List<String>.unmodifiable(imagePaths);
    final List<Corners?> cornersList;
    try {
      cornersList = await compute(_seedBatchInIsolate, paths);
    } catch (e, st) {
      _log.w('opencv batch seed failed, falling back to sequential',
          {'err': e.toString()});
      _log.d('stack', st);
      // Fallback: run sequentially on main. Equivalent to the
      // pre-V.9 per-page path.
      final results = <SeedResult>[];
      for (final p in paths) {
        results.add(await seed(p));
      }
      return results;
    }
    sw.stop();
    int okCount = 0;
    int fellBackCount = 0;
    final out = <SeedResult>[];
    for (int i = 0; i < paths.length; i++) {
      final c = cornersList[i];
      if (c != null) {
        out.add(SeedResult(corners: c, fellBack: false));
        okCount++;
      } else {
        out.add(await fallback.seed(paths[i]));
        fellBackCount++;
      }
    }
    _log.i('batch seed complete', {
      'ms': sw.elapsedMilliseconds,
      'pages': paths.length,
      'openCvOk': okCount,
      'fellBack': fellBackCount,
    });
    return out;
  }

  /// Cap the working image at ~720 px long edge — Canny + findContours
  /// scale roughly with pixel count, so this is a 5–8× speedup over
  /// running on full source resolution and the quad shape is
  /// unaffected by the downscale.
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

  /// Run the full opencv pipeline on [small] and return normalised
  /// [Corners] in the source frame, or null when nothing convincing
  /// was found.
  Corners? _detectQuad(img.Image small) {
    cv.Mat? srcMat;
    cv.Mat? gray;
    cv.Mat? blurred;
    cv.Mat? edges;
    cv.Mat? dilated;
    cv.Mat? kernel;
    cv.VecVecPoint? contours;
    cv.VecVec4i? hierarchy;
    try {
      final w = small.width;
      final h = small.height;
      final flat = small.convert(numChannels: 3)
          .getBytes(order: img.ChannelOrder.bgr);
      srcMat = cv.Mat.fromList(h, w, cv.MatType.CV_8UC3, flat);
      gray = cv.cvtColor(srcMat, cv.COLOR_BGR2GRAY);
      blurred = cv.gaussianBlur(gray, (5, 5), 0);
      edges = cv.canny(blurred, 50, 150);
      kernel = cv.getStructuringElement(cv.MORPH_RECT, (3, 3));
      dilated = cv.dilate(edges, kernel);

      final result = cv.findContours(
        dilated,
        cv.RETR_LIST,
        cv.CHAIN_APPROX_SIMPLE,
      );
      contours = result.$1;
      hierarchy = result.$2;

      final frameArea = (w * h).toDouble();
      Corners? bestCorners;
      var bestArea = 0.0;
      for (var i = 0; i < contours.length; i++) {
        final c = contours[i];
        final area = cv.contourArea(c);
        if (area < frameArea * 0.10) continue;
        final perimeter = cv.arcLength(c, true);
        final approx = cv.approxPolyDP(c, perimeter * 0.02, true);
        if (approx.length != 4) {
          approx.dispose();
          continue;
        }
        if (area > bestArea) {
          bestArea = area;
          bestCorners = _normalisedCornersFromQuad(approx, w, h);
        }
        approx.dispose();
      }
      return bestCorners;
    } finally {
      srcMat?.dispose();
      gray?.dispose();
      blurred?.dispose();
      edges?.dispose();
      kernel?.dispose();
      dilated?.dispose();
      contours?.dispose();
      hierarchy?.dispose();
    }
  }

  /// Phase V.9: top-level worker function. Runs the full OpenCV
  /// pipeline on every path inside ONE isolate; returns a parallel
  /// `List<Corners?>` where null entries signal "worker couldn't
  /// detect a quad — main isolate should dispatch to fallback."
  ///
  /// Static because `compute()` requires a top-level or static
  /// function (closures over `this` can't cross the isolate
  /// boundary). Pulls no instance state — uses only the static
  /// helpers below.
  static List<Corners?> _seedBatchInIsolate(List<String> paths) {
    return [for (final p in paths) _seedOneForBatch(p)];
  }

  /// One page of the batch: decode, downscale, OpenCV detect. Never
  /// throws — returns `null` on any failure so the caller can fall
  /// back on main.
  static Corners? _seedOneForBatch(String path) {
    try {
      final bytes = File(path).readAsBytesSync();
      final decoded = img.decodeImage(bytes);
      if (decoded == null) return null;
      final small = _downscaleStatic(decoded);
      return _detectQuadStatic(small);
    } catch (_) {
      return null;
    }
  }

  /// Static twin of [_downscale] for use inside the batch worker.
  /// Kept separate so the instance method's default arg remains
  /// private.
  static img.Image _downscaleStatic(img.Image src) {
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

  /// Static twin of [_detectQuad]. Runs the full OpenCV contour
  /// pipeline on a small image and returns normalized [Corners] or
  /// null. Every Mat allocation is release-guaranteed via a `try /
  /// finally`, same as the instance method.
  static Corners? _detectQuadStatic(img.Image small) {
    cv.Mat? srcMat;
    cv.Mat? gray;
    cv.Mat? blurred;
    cv.Mat? edges;
    cv.Mat? dilated;
    cv.Mat? kernel;
    cv.VecVecPoint? contours;
    cv.VecVec4i? hierarchy;
    try {
      final w = small.width;
      final h = small.height;
      final flat = small.convert(numChannels: 3)
          .getBytes(order: img.ChannelOrder.bgr);
      srcMat = cv.Mat.fromList(h, w, cv.MatType.CV_8UC3, flat);
      gray = cv.cvtColor(srcMat, cv.COLOR_BGR2GRAY);
      blurred = cv.gaussianBlur(gray, (5, 5), 0);
      edges = cv.canny(blurred, 50, 150);
      kernel = cv.getStructuringElement(cv.MORPH_RECT, (3, 3));
      dilated = cv.dilate(edges, kernel);

      final result = cv.findContours(
        dilated,
        cv.RETR_LIST,
        cv.CHAIN_APPROX_SIMPLE,
      );
      contours = result.$1;
      hierarchy = result.$2;

      final frameArea = (w * h).toDouble();
      Corners? bestCorners;
      var bestArea = 0.0;
      for (var i = 0; i < contours.length; i++) {
        final c = contours[i];
        final area = cv.contourArea(c);
        if (area < frameArea * 0.10) continue;
        final perimeter = cv.arcLength(c, true);
        final approx = cv.approxPolyDP(c, perimeter * 0.02, true);
        if (approx.length != 4) {
          approx.dispose();
          continue;
        }
        if (area > bestArea) {
          bestArea = area;
          bestCorners = _normalisedCornersFromQuadStatic(approx, w, h);
        }
        approx.dispose();
      }
      return bestCorners;
    } finally {
      srcMat?.dispose();
      gray?.dispose();
      blurred?.dispose();
      edges?.dispose();
      kernel?.dispose();
      dilated?.dispose();
      contours?.dispose();
      hierarchy?.dispose();
    }
  }

  /// Static twin of [_normalisedCornersFromQuad].
  static Corners _normalisedCornersFromQuadStatic(
      cv.VecPoint quad, int w, int h) {
    final pts = <(double, double)>[
      for (var i = 0; i < quad.length; i++)
        (quad[i].x.toDouble(), quad[i].y.toDouble())
    ];
    pts.sort((a, b) => (a.$1 + a.$2).compareTo(b.$1 + b.$2));
    final tl = pts.first;
    final br = pts.last;
    final mid = pts.sublist(1, pts.length - 1)
      ..sort((a, b) => (a.$1 - a.$2).compareTo(b.$1 - b.$2));
    final bl = mid.first;
    final tr = mid.last;

    Point2 norm((double, double) p) =>
        Point2((p.$1 / (w - 1)).clamp(0.0, 1.0),
            (p.$2 / (h - 1)).clamp(0.0, 1.0));

    return Corners(norm(tl), norm(tr), norm(br), norm(bl));
  }

  /// Order [quad]'s four points TL/TR/BR/BL by sum and difference of
  /// coords — robust against the arbitrary order findContours
  /// returns. Then convert pixel coords into the [0..1] domain Corners
  /// expects.
  Corners _normalisedCornersFromQuad(cv.VecPoint quad, int w, int h) {
    final pts = <(double, double)>[
      for (var i = 0; i < quad.length; i++)
        (quad[i].x.toDouble(), quad[i].y.toDouble())
    ];
    // TL has the smallest x+y; BR the largest. TR has the largest
    // x-y; BL the smallest x-y.
    pts.sort((a, b) => (a.$1 + a.$2).compareTo(b.$1 + b.$2));
    final tl = pts.first;
    final br = pts.last;
    final mid = pts.sublist(1, pts.length - 1)
      ..sort((a, b) => (a.$1 - a.$2).compareTo(b.$1 - b.$2));
    final bl = mid.first;
    final tr = mid.last;

    Point2 norm((double, double) p) =>
        Point2((p.$1 / (w - 1)).clamp(0.0, 1.0),
            (p.$2 / (h - 1)).clamp(0.0, 1.0));

    return Corners(norm(tl), norm(tr), norm(br), norm(bl));
  }
}
