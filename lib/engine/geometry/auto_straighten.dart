import 'dart:io';
import 'dart:math' as math;

import 'package:image/image.dart' as img;
import 'package:opencv_dart/opencv_dart.dart' as cv;

import '../../core/logging/app_logger.dart';

final _log = AppLogger('AutoStraighten');

/// Estimate the skew angle (degrees, positive = rotate clockwise to
/// straighten) of [src] using OpenCV's Canny + probabilistic Hough.
/// Returns null when there aren't enough lines to be confident, or
/// when the OpenCV native library can't load (test environments).
///
/// ## Phase XVI.37 — shared between scanner + editor
///
/// Lifted from `lib/features/scanner/data/image_processor.dart`.
/// The scanner still calls in via the same name; the editor's
/// "Auto" straighten button calls [estimateDeskewFromPath] which
/// wraps the synchronous decode + this function.
///
/// Algorithm:
///   1. Grayscale + downscale to ~640 px long edge for speed.
///   2. Canny edge map (50 / 150).
///   3. HoughLinesP — only "long" lines (>= 20 % of long edge).
///   4. For each line compute angle in [-45°, +45°].
///   5. Median is the skew; reject if fewer than 8 lines survive.
double? estimateDeskewDegrees(img.Image src) {
  cv.Mat? srcMat;
  cv.Mat? gray;
  cv.Mat? edges;
  cv.Mat? lines;
  try {
    final smaller = _resizeForDeskew(src);
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
    final minLineLen = math.max(20.0, longEdge * 0.2);
    lines = cv.HoughLinesP(
      edges,
      1,
      math.pi / 180,
      80,
      minLineLength: minLineLen,
      maxLineGap: 10,
    );

    final angles = <double>[];
    for (var i = 0; i < lines.rows; i++) {
      // Each row is [x1, y1, x2, y2] as int32.
      final x1 = lines.at<int>(i, 0);
      final y1 = lines.at<int>(i, 1);
      final x2 = lines.at<int>(i, 2);
      final y2 = lines.at<int>(i, 3);
      final dx = (x2 - x1).toDouble();
      final dy = (y2 - y1).toDouble();
      if (dx == 0 && dy == 0) continue;
      var deg = math.atan2(dy, dx) * 180 / math.pi;
      // Collapse vertical lines into the horizontal frame so a
      // 90°-rotated page still resolves to the same skew bucket.
      if (deg > 90) deg -= 180;
      if (deg < -90) deg += 180;
      if (deg > 45) deg -= 90;
      if (deg < -45) deg += 90;
      angles.add(deg);
    }
    if (angles.length < 8) return null;
    angles.sort();
    final median = angles[angles.length ~/ 2];
    if (median.abs() < 0.2) return 0; // already straight
    return median;
  } catch (_) {
    return null;
  } finally {
    srcMat?.dispose();
    gray?.dispose();
    edges?.dispose();
    lines?.dispose();
  }
}

img.Image _resizeForDeskew(img.Image src) {
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

/// Path-based wrapper used by the editor's Auto-straighten button.
///
/// Decodes [path] via `package:image`, runs [estimateDeskewDegrees],
/// and returns the angle (or null on any failure — decode error,
/// missing OpenCV, not enough lines, or already-level page). The
/// editor session translates a non-null result into a `setScalar`
/// on `EditOpType.straighten`. Silent fallback: nothing is committed
/// when the function returns null.
Future<double?> estimateDeskewFromPath(String path) async {
  try {
    final file = File(path);
    if (!await file.exists()) return null;
    final bytes = await file.readAsBytes();
    final src = img.decodeImage(bytes);
    if (src == null) return null;
    return estimateDeskewDegrees(src);
  } catch (e) {
    _log.w('estimateDeskewFromPath failed', {'error': e.toString()});
    return null;
  }
}
