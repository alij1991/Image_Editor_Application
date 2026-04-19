import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;
import 'package:opencv_dart/opencv_dart.dart' as cv;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';

import '../../../core/logging/app_logger.dart';
import '../domain/models/scan_models.dart';

final _log = AppLogger('ScanImgProc');

/// Perspective-warps a page according to its [Corners] and applies its
/// [ScanFilter], writing the result as a JPEG into the app's temp dir.
///
/// The CPU-heavy part (decode → warp → filter → encode) runs in a
/// background isolate via `compute()` so the UI thread stays smooth
/// during filter changes, rotations, and corner edits.
///
/// Two render paths:
///   - [process] produces a full-resolution JPEG (long edge capped at
///     [maxOutputEdge], default 2400 px) suitable for export. Slow on
///     12 MP captures (3-7 s on a mid-tier phone).
///   - [processPreview] produces a 1024-px proxy in a fraction of the
///     time (typically 200-700 ms). The notifier kicks this off first
///     so the preview reflects the user's filter / crop / rotate tap
///     immediately, then chains the full-res render in the background.
class ScanImageProcessor {
  ScanImageProcessor({
    this.maxOutputEdge = 2400,
    this.previewEdge = 1024,
    this.jpegQuality = 88,
    this.previewQuality = 80,
  });

  final int maxOutputEdge;
  final int previewEdge;
  final int jpegQuality;
  final int previewQuality;

  Future<ScanPage> process(ScanPage page) =>
      _runOnce(page, edge: maxOutputEdge, quality: jpegQuality, label: 'full');

  /// Fast feedback render: same pipeline as [process] but capped at
  /// [previewEdge] (default 1024 px) with a slightly lower JPEG
  /// quality. Returns the page with [ScanPage.processedImagePath] set
  /// to the preview path. Cheap to throw away — the caller usually
  /// chases this with a [process] call to land the full-res version.
  Future<ScanPage> processPreview(ScanPage page) =>
      _runOnce(page,
          edge: previewEdge, quality: previewQuality, label: 'preview');

  Future<ScanPage> _runOnce(
    ScanPage page, {
    required int edge,
    required int quality,
    required String label,
  }) async {
    final sw = Stopwatch()..start();
    final bytes = await File(page.rawImagePath).readAsBytes();
    final payload = _ProcessPayload(
      bytes: bytes,
      corners: page.corners,
      rotationDeg: page.rotationDeg,
      filter: page.filter,
      maxOutputEdge: edge,
      jpegQuality: quality,
    );
    Uint8List jpeg;
    try {
      jpeg = await compute(_processInIsolate, payload);
    } catch (e, st) {
      _log.e('isolate failed, running on main', error: e, stackTrace: st);
      jpeg = _processInIsolate(payload);
    }
    if (jpeg.isEmpty) {
      _log.w('decode failed', {'path': page.rawImagePath, 'mode': label});
      return page;
    }
    final path = await _writeTemp(jpeg, page.id, mode: label);
    _log.d('processed', {
      'page': page.id,
      'bytes': jpeg.length,
      'ms': sw.elapsedMilliseconds,
      'filter': page.filter.name,
      'mode': label,
    });
    return page.copyWith(processedImagePath: path);
  }

  Future<String> _writeTemp(Uint8List bytes, String pageId,
      {required String mode}) async {
    final dir = await getTemporaryDirectory();
    final scansDir = Directory(p.join(dir.path, 'scans'));
    if (!scansDir.existsSync()) scansDir.createSync(recursive: true);
    final path = p.join(
      scansDir.path,
      'page_${pageId}_${mode}_${const Uuid().v4().substring(0, 8)}.jpg',
    );
    await File(path).writeAsBytes(bytes);
    return path;
  }
}

/// Message passed to the isolate. All fields are cheap-to-copy value
/// types so the SendPort marshalling is inexpensive.
class _ProcessPayload {
  const _ProcessPayload({
    required this.bytes,
    required this.corners,
    required this.rotationDeg,
    required this.filter,
    required this.maxOutputEdge,
    required this.jpegQuality,
  });

  final Uint8List bytes;
  final Corners corners;
  final double rotationDeg;
  final ScanFilter filter;
  final int maxOutputEdge;
  final int jpegQuality;
}

/// Top-level isolate entry point — must be top-level (or static) for
/// `compute()`. Returns the encoded JPEG or an empty list on decode
/// failure so the caller can log and fall back to the raw file.
Uint8List _processInIsolate(_ProcessPayload payload) {
  final decoded = img.decodeImage(payload.bytes);
  if (decoded == null) return Uint8List(0);

  img.Image out;
  if (_isFullRect(payload.corners)) {
    out = decoded;
  } else {
    out = _perspectiveWarp(decoded, payload.corners);
  }

  if (payload.rotationDeg.abs() > 0.01) {
    out = img.copyRotate(out, angle: payload.rotationDeg);
  }

  out = _applyFilter(out, payload.filter);
  out = _fitLongEdge(out, payload.maxOutputEdge);

  return Uint8List.fromList(img.encodeJpg(out, quality: payload.jpegQuality));
}

bool _isFullRect(Corners c) {
  const eps = 0.01;
  return c.tl.x < eps &&
      c.tl.y < eps &&
      c.tr.x > 1 - eps &&
      c.tr.y < eps &&
      c.br.x > 1 - eps &&
      c.br.y > 1 - eps &&
      c.bl.x < eps &&
      c.bl.y > 1 - eps;
}

/// OpenCV-backed perspective warp. Builds the source-quad → axis-aligned
/// rectangle transform, runs `cv.warpPerspective` (native, multi-threaded
/// inside libopencv_imgproc), then copies the BGR output bytes back into
/// an `img.Image` so the rest of the pipeline can stay on the existing
/// pure-Dart filter chain.
///
/// Falls back to [_perspectiveWarpDart] on any FFI failure (e.g. native
/// library unavailable in a test runner) so the scanner keeps working
/// even when OpenCV can't load.
img.Image _perspectiveWarp(img.Image src, Corners c) {
  try {
    return _perspectiveWarpOpenCv(src, c);
  } catch (_) {
    return _perspectiveWarpDart(src, c);
  }
}

img.Image _perspectiveWarpOpenCv(img.Image src, Corners c) {
  final srcW = src.width.toDouble();
  final srcH = src.height.toDouble();
  final pts = [
    (c.tl.x * srcW, c.tl.y * srcH),
    (c.tr.x * srcW, c.tr.y * srcH),
    (c.br.x * srcW, c.br.y * srcH),
    (c.bl.x * srcW, c.bl.y * srcH),
  ];
  final (outW, outH) = _outputDimsFor(pts);

  // Build the source 8UC3 Mat from the decoded pixels. Mat expects BGR
  // ordering; we copy RGB into BGR slots to skip a separate cvtColor.
  final srcRgb = img.Image.from(src).convert(numChannels: 3);
  final flat = srcRgb.getBytes(order: img.ChannelOrder.bgr);

  final srcMat = cv.Mat.fromList(
    src.height,
    src.width,
    cv.MatType.CV_8UC3,
    flat,
  );
  final srcQuad = cv.VecPoint.fromList(
    pts.map((p) => cv.Point(p.$1.round(), p.$2.round())).toList(),
  );
  final dstQuad = cv.VecPoint.fromList([
    cv.Point(0, 0),
    cv.Point(outW - 1, 0),
    cv.Point(outW - 1, outH - 1),
    cv.Point(0, outH - 1),
  ]);

  cv.Mat? mTransform;
  cv.Mat? warped;
  try {
    mTransform = cv.getPerspectiveTransform(srcQuad, dstQuad);
    warped = cv.warpPerspective(srcMat, mTransform, (outW, outH));
    // Mat.data is a view onto FFI memory — copy out before disposing.
    final outBytes = Uint8List.fromList(warped.data);
    return img.Image.fromBytes(
      width: outW,
      height: outH,
      bytes: outBytes.buffer,
      order: img.ChannelOrder.bgr,
      numChannels: 3,
    );
  } finally {
    srcMat.dispose();
    srcQuad.dispose();
    dstQuad.dispose();
    mTransform?.dispose();
    warped?.dispose();
  }
}

(int, int) _outputDimsFor(List<(double, double)> pts) {
  double dist((double, double) a, (double, double) b) {
    final dx = a.$1 - b.$1;
    final dy = a.$2 - b.$2;
    return math.sqrt(dx * dx + dy * dy);
  }

  final widthTop = dist(pts[0], pts[1]);
  final widthBot = dist(pts[3], pts[2]);
  final heightL = dist(pts[0], pts[3]);
  final heightR = dist(pts[1], pts[2]);
  final outW = ((widthTop + widthBot) / 2).round().clamp(64, 8000);
  final outH = ((heightL + heightR) / 2).round().clamp(64, 8000);
  return (outW, outH);
}

/// Pure-Dart bilinear warp — kept as a fallback for environments where
/// the OpenCV native library can't load (Flutter test runner, an
/// unsupported platform, or a native-asset build hiccup). Visually
/// identical to the OpenCV path within rounding noise, just slower.
img.Image _perspectiveWarpDart(img.Image src, Corners c) {
  final srcW = src.width.toDouble();
  final srcH = src.height.toDouble();
  final tl = (c.tl.x * srcW, c.tl.y * srcH);
  final tr = (c.tr.x * srcW, c.tr.y * srcH);
  final br = (c.br.x * srcW, c.br.y * srcH);
  final bl = (c.bl.x * srcW, c.bl.y * srcH);
  final (outW, outH) = _outputDimsFor([tl, tr, br, bl]);

  final out = img.Image(width: outW, height: outH, numChannels: 3);
  for (var y = 0; y < outH; y++) {
    final v = y / (outH - 1);
    final lx = tl.$1 + (bl.$1 - tl.$1) * v;
    final ly = tl.$2 + (bl.$2 - tl.$2) * v;
    final rx = tr.$1 + (br.$1 - tr.$1) * v;
    final ry = tr.$2 + (br.$2 - tr.$2) * v;
    for (var x = 0; x < outW; x++) {
      final u = x / (outW - 1);
      final sx = lx + (rx - lx) * u;
      final sy = ly + (ry - ly) * u;
      final px = _sampleBilinear(src, sx, sy);
      out.setPixelRgb(x, y, px.$1, px.$2, px.$3);
    }
  }
  return out;
}

(int, int, int) _sampleBilinear(img.Image src, double x, double y) {
  if (x < 0) x = 0;
  if (y < 0) y = 0;
  if (x > src.width - 1) x = src.width - 1.0;
  if (y > src.height - 1) y = src.height - 1.0;
  final x0 = x.floor();
  final y0 = y.floor();
  final x1 = math.min(x0 + 1, src.width - 1);
  final y1 = math.min(y0 + 1, src.height - 1);
  final fx = x - x0;
  final fy = y - y0;
  final p00 = src.getPixel(x0, y0);
  final p10 = src.getPixel(x1, y0);
  final p01 = src.getPixel(x0, y1);
  final p11 = src.getPixel(x1, y1);
  double lerp(num a, num b, double t) => a + (b - a) * t;
  final r = lerp(lerp(p00.r, p10.r, fx), lerp(p01.r, p11.r, fx), fy);
  final g = lerp(lerp(p00.g, p10.g, fx), lerp(p01.g, p11.g, fx), fy);
  final b = lerp(lerp(p00.b, p10.b, fx), lerp(p01.b, p11.b, fx), fy);
  return (
    r.round().clamp(0, 255),
    g.round().clamp(0, 255),
    b.round().clamp(0, 255),
  );
}

img.Image _applyFilter(img.Image src, ScanFilter filter) {
  switch (filter) {
    case ScanFilter.auto:
      return img.adjustColor(src, contrast: 1.08, saturation: 1.03);
    case ScanFilter.color:
      return img.adjustColor(src, contrast: 1.15, saturation: 1.15);
    case ScanFilter.grayscale:
      return img.grayscale(img.adjustColor(src, contrast: 1.1));
    case ScanFilter.bw:
      // Try the OpenCV-backed adaptive threshold first; falls back to
      // the pure-Dart integral-image variant when the native lib
      // isn't available (test runner) or any FFI step throws.
      return binarizeWithOpenCv(src) ?? _adaptiveThreshold(img.grayscale(src));
    case ScanFilter.magicColor:
      return magicColorWithOpenCv(src) ?? _magicColor(src);
  }
}

/// Adaptive Gaussian threshold via opencv_dart. Per-pixel threshold
/// derived from a 31×31 Gaussian-weighted mean of the surrounding
/// luminance, with a small constant subtracted so anti-aliased text
/// edges resolve as black. Returns null on FFI failure so the caller
/// can fall back to the pure-Dart integral-image path. Public so
/// tests can exercise the filter without going through the
/// path_provider-dependent `ScanImageProcessor.process()`.
img.Image? binarizeWithOpenCv(img.Image src) {
  cv.Mat? srcMat;
  cv.Mat? gray;
  cv.Mat? bin;
  try {
    final w = src.width;
    final h = src.height;
    final flat = src.convert(numChannels: 3)
        .getBytes(order: img.ChannelOrder.bgr);
    srcMat = cv.Mat.fromList(h, w, cv.MatType.CV_8UC3, flat);
    gray = cv.cvtColor(srcMat, cv.COLOR_BGR2GRAY);
    bin = cv.adaptiveThreshold(
      gray,
      255,
      cv.ADAPTIVE_THRESH_GAUSSIAN_C,
      cv.THRESH_BINARY,
      31, // odd block size — wide enough for text strokes, narrow
          // enough to track lighting gradients.
      8,  // C subtracted from the mean: pulls anti-aliased edges into
          // the black bucket without crushing thin strokes.
    );
    final outBytes = Uint8List.fromList(bin.data);
    // adaptiveThreshold returns single-channel — wrap as luminance and
    // expand to 3 channels so the rest of the pipeline (encoder,
    // exporter) sees a uniform RGB shape.
    final mono = img.Image.fromBytes(
      width: w,
      height: h,
      bytes: outBytes.buffer,
      numChannels: 1,
    );
    return mono.convert(numChannels: 3);
  } catch (_) {
    return null;
  } finally {
    srcMat?.dispose();
    gray?.dispose();
    bin?.dispose();
  }
}

/// Magic colour via opencv_dart: divides the source by a heavy
/// Gaussian-blurred copy of itself per channel — a multi-scale Retinex
/// reduction to one scale, which lifts uneven illumination (the
/// sloping shadow under a hand-held capture) without crushing colour
/// fidelity. Followed by a mild contrast / saturation boost. Public
/// so tests can exercise it without going through the
/// path_provider-dependent `ScanImageProcessor.process()`.
img.Image? magicColorWithOpenCv(img.Image src) {
  cv.Mat? srcMat;
  cv.Mat? srcF;
  cv.Mat? blur;
  cv.Mat? blurF;
  cv.Mat? norm;
  cv.Mat? out8;
  try {
    final w = src.width;
    final h = src.height;
    final flat = src.convert(numChannels: 3)
        .getBytes(order: img.ChannelOrder.bgr);
    srcMat = cv.Mat.fromList(h, w, cv.MatType.CV_8UC3, flat);
    // Kernel size scales with the long edge so the blur "sees" only
    // the slow illumination gradient, not local text strokes.
    final longEdge = math.max(w, h);
    var k = (longEdge / 8).round();
    if (k.isEven) k += 1; // Gaussian needs odd ksize
    if (k < 31) k = 31;
    blur = cv.gaussianBlur(srcMat, (k, k), 0);
    // Convert both to float so the divide doesn't truncate. Use a
    // scale factor of 220 (out of 255) so the output looks lifted
    // without saturating the page background to pure white.
    srcF = srcMat.convertTo(cv.MatType.CV_32FC3);
    blurF = blur.convertTo(cv.MatType.CV_32FC3);
    norm = cv.divide(srcF, blurF, scale: 220);
    out8 = norm.convertTo(cv.MatType.CV_8UC3);
    final outBytes = Uint8List.fromList(out8.data);
    final lifted = img.Image.fromBytes(
      width: w,
      height: h,
      bytes: outBytes.buffer,
      order: img.ChannelOrder.bgr,
      numChannels: 3,
    );
    // Mild final pop — same numbers as the pure-Dart magic colour path
    // so users don't see a discontinuity when falling back.
    return img.adjustColor(lifted,
        contrast: 1.15, saturation: 1.15, brightness: 1.02);
  } catch (_) {
    return null;
  } finally {
    srcMat?.dispose();
    srcF?.dispose();
    blur?.dispose();
    blurF?.dispose();
    norm?.dispose();
    out8?.dispose();
  }
}

/// Magic-color: gray-world white balance → illumination normalisation
/// via a downscaled gaussian blur (kept small so this stays snappy) →
/// contrast / saturation boost.
img.Image _magicColor(img.Image src) {
  // 1. Gray-world white balance.
  var rSum = 0.0, gSum = 0.0, bSum = 0.0;
  final n = src.width * src.height;
  for (final px in src) {
    rSum += px.r;
    gSum += px.g;
    bSum += px.b;
  }
  final rMean = rSum / n;
  final gMean = gSum / n;
  final bMean = bSum / n;
  final gray = (rMean + gMean + bMean) / 3.0;
  final rGain = rMean == 0 ? 1.0 : gray / rMean;
  final gGain = gMean == 0 ? 1.0 : gray / gMean;
  final bGain = bMean == 0 ? 1.0 : gray / bMean;
  final wb = img.Image.from(src);
  for (final px in wb) {
    px
      ..r = (px.r * rGain).clamp(0, 255)
      ..g = (px.g * gGain).clamp(0, 255)
      ..b = (px.b * bGain).clamp(0, 255);
  }

  // 2. Illumination normalisation — blur on a downscaled copy (fast),
  //    then upscale before the pixel-wise divide. Produces visually
  //    identical results to a full-res blur but 10–30x quicker.
  if (math.min(src.width, src.height) > 200) {
    const smallLong = 320;
    final longEdge = math.max(wb.width, wb.height);
    final scale = longEdge > smallLong ? smallLong / longEdge : 1.0;
    final blurSrc = scale < 1.0
        ? img.copyResize(
            img.Image.from(wb),
            width: (wb.width * scale).round(),
            height: (wb.height * scale).round(),
            interpolation: img.Interpolation.linear,
          )
        : img.Image.from(wb);
    final blurredSmall =
        img.gaussianBlur(blurSrc, radius: 6); // cheap radius on downscaled
    final blurred = scale < 1.0
        ? img.copyResize(
            blurredSmall,
            width: wb.width,
            height: wb.height,
            interpolation: img.Interpolation.linear,
          )
        : blurredSmall;
    for (var y = 0; y < wb.height; y++) {
      for (var x = 0; x < wb.width; x++) {
        final fg = wb.getPixel(x, y);
        final bg = blurred.getPixel(x, y);
        double norm(num f, num b) =>
            (b == 0 ? 255.0 : (f / b) * 220.0).clamp(0, 255).toDouble();
        wb.setPixelRgb(
          x,
          y,
          norm(fg.r, bg.r).round(),
          norm(fg.g, bg.g).round(),
          norm(fg.b, bg.b).round(),
        );
      }
    }
  }

  return img.adjustColor(wb, contrast: 1.2, saturation: 1.2, brightness: 1.02);
}

/// Adaptive threshold via a 2D integral image — O(1) per-pixel lookup
/// so this runs in a single linear pass regardless of window size.
img.Image _adaptiveThreshold(img.Image gray) {
  final w = gray.width;
  final h = gray.height;
  final window = math.max(9, (w / 40).round() | 1); // odd
  final half = window ~/ 2;

  // Luminance buffer.
  final lum = Uint8List(w * h);
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      lum[y * w + x] = gray.getPixel(x, y).r.round().clamp(0, 255);
    }
  }

  // 2D integral image: integral[y*w + x] = sum of lum[0..y][0..x].
  // We use Int64List so the running sum doesn't overflow on big images
  // (2400*1600*255 ≈ 9.7e8, within int32 but cutting it close).
  final integral = Int64List(w * h);
  for (var y = 0; y < h; y++) {
    var rowAcc = 0;
    for (var x = 0; x < w; x++) {
      rowAcc += lum[y * w + x];
      final above = y == 0 ? 0 : integral[(y - 1) * w + x];
      integral[y * w + x] = above + rowAcc;
    }
  }

  int rectSum(int x0, int y0, int x1, int y1) {
    // Inclusive bounds. Uses the classic 4-point integral-image formula.
    final a = integral[y1 * w + x1];
    final b = y0 == 0 ? 0 : integral[(y0 - 1) * w + x1];
    final c = x0 == 0 ? 0 : integral[y1 * w + (x0 - 1)];
    final d = (x0 == 0 || y0 == 0)
        ? 0
        : integral[(y0 - 1) * w + (x0 - 1)];
    return a - b - c + d;
  }

  final out = img.Image(width: w, height: h, numChannels: 3);
  const c = 8; // pixel must be c darker than the local mean to become black
  for (var y = 0; y < h; y++) {
    final y0 = math.max(0, y - half);
    final y1 = math.min(h - 1, y + half);
    for (var x = 0; x < w; x++) {
      final x0 = math.max(0, x - half);
      final x1 = math.min(w - 1, x + half);
      final sum = rectSum(x0, y0, x1, y1);
      final count = (y1 - y0 + 1) * (x1 - x0 + 1);
      final mean = sum / count;
      final v = lum[y * w + x];
      final bit = v < mean - c ? 0 : 255;
      out.setPixelRgb(x, y, bit, bit, bit);
    }
  }
  return out;
}

/// Estimate the skew angle (degrees, positive = rotate clockwise to
/// straighten) of [src] using OpenCV's Canny + probabilistic Hough.
/// Returns null when there aren't enough lines to be confident, or
/// when the OpenCV native library can't load (test environments).
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
    final flat = smaller.convert(numChannels: 3)
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

img.Image _fitLongEdge(img.Image src, int maxEdge) {
  final longEdge = math.max(src.width, src.height);
  if (longEdge <= maxEdge) return src;
  final scale = maxEdge / longEdge;
  return img.copyResize(
    src,
    width: (src.width * scale).round(),
    height: (src.height * scale).round(),
    interpolation: img.Interpolation.linear,
  );
}
