import 'dart:math' as math;

import 'package:image/image.dart' as img;
import 'package:opencv_dart/opencv_dart.dart' as cv;

import '../../../core/logging/app_logger.dart';

final _log = AppLogger('AutoRotate');

/// Pure-CV orientation classifier. Returns the rotation (in degrees,
/// positive = clockwise) the page should be rotated by to land in
/// the natural landscape/portrait orientation.
///
/// Approach: documents are dominated by horizontal text-line edges.
/// We Canny + Hough on a downscaled grayscale, classify each long
/// line as horizontal or vertical, and infer:
///   - mostly horizontal lines  → page already correct → 0°
///   - mostly vertical lines    → page is sideways → 90° or 270°
/// We can't disambiguate 90° vs 270° (top-vs-bottom) without text
/// understanding, so we always return +90° in the sideways case
/// (the user can hit the "rotate again" button if it landed
/// upside-down). Returns null when the line count is too small to
/// be confident or when the OpenCV native lib failed to load.
///
/// 180° detection requires recognising upside-down text, which
/// needs an actual OCR pass or an orientation model — out of scope
/// here. The caller is expected to pair this with a "Rotate page"
/// button so the user can finish the job manually.
int? estimateRotationDegrees(img.Image src) {
  cv.Mat? srcMat;
  cv.Mat? gray;
  cv.Mat? edges;
  cv.Mat? lines;
  try {
    final smaller = _resizeForRotate(src);
    final flat = smaller
        .convert(numChannels: 3)
        .getBytes(order: img.ChannelOrder.bgr);
    srcMat = cv.Mat.fromList(
      smaller.height,
      smaller.width,
      cv.MatType.CV_8UC3,
      flat,
    );
    gray = cv.cvtColor(srcMat, cv.COLOR_BGR2GRAY);
    edges = cv.canny(gray, 50, 150);

    final longEdge = math.max(smaller.width, smaller.height).toDouble();
    final minLineLen = math.max(20.0, longEdge * 0.15);
    lines = cv.HoughLinesP(
      edges,
      1,
      math.pi / 180,
      80,
      minLineLength: minLineLen,
      maxLineGap: 12,
    );

    var horizontal = 0;
    var vertical = 0;
    for (var i = 0; i < lines.rows; i++) {
      final x1 = lines.at<int>(i, 0);
      final y1 = lines.at<int>(i, 1);
      final x2 = lines.at<int>(i, 2);
      final y2 = lines.at<int>(i, 3);
      final dx = (x2 - x1).abs();
      final dy = (y2 - y1).abs();
      if (dx == 0 && dy == 0) continue;
      // Ignore lines within ±20° of either axis as "ambiguous diagonals"
      // so a page printed entirely in italics or tables doesn't get
      // mis-classified.
      if (dx > dy * 2.5) {
        horizontal++;
      } else if (dy > dx * 2.5) {
        vertical++;
      }
    }
    final total = horizontal + vertical;
    if (total < 10) {
      _log.d('not enough confident lines', {'total': total});
      return null;
    }
    // 60 % majority threshold so a roughly square page with mixed
    // line directions doesn't get rotated unnecessarily.
    if (vertical >= horizontal * 1.5) {
      _log.i('sideways detected', {'h': horizontal, 'v': vertical});
      return 90;
    }
    if (horizontal >= vertical * 1.5) {
      return 0;
    }
    return null;
  } catch (e) {
    _log.w('rotate estimator failed', {'err': e.toString()});
    return null;
  } finally {
    srcMat?.dispose();
    gray?.dispose();
    edges?.dispose();
    lines?.dispose();
  }
}

img.Image _resizeForRotate(img.Image src) {
  const target = 640;
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
