import 'dart:io';
import 'dart:isolate';
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
      brightness: page.brightness,
      contrast: page.contrast,
      thresholdOffset: page.thresholdOffset,
      magicScale: page.magicScale,
    );
    // Phase X.B.3 — migrated from `compute()` to `Isolate.run` with a
    // restart path. Pre-X.B.3 an isolate failure fell back to running
    // `_processInIsolate` on the main thread, freezing the UI for 3-7s
    // on 12 MP captures. Post-X.B.3 we retry once in a fresh isolate;
    // if both attempts fail we degrade to the empty-return contract
    // (same shape as a decode failure) so the caller leaves the page
    // on its placeholder. Main-thread execution is never reached for a
    // user-facing render.
    final jpeg = await _runOffThread(payload);
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
    this.brightness = 0,
    this.contrast = 0,
    this.thresholdOffset = 0,
    this.magicScale = 220,
  });

  final Uint8List bytes;
  final Corners corners;
  final double rotationDeg;
  final ScanFilter filter;
  final int maxOutputEdge;
  final int jpegQuality;

  /// Per-page fine-tune applied AFTER the filter pipeline (or, for
  /// the bw filter, baked into the threshold C-value).
  final double brightness;
  final double contrast;
  final double thresholdOffset;
  final double magicScale;
}

/// Phase X.B.3 — run the CPU-heavy pipeline in a background isolate,
/// retrying once in a fresh isolate before giving up. The empty-return
/// is the same graceful-degrade signal the decoder already uses, so
/// the caller doesn't need a separate error path.
///
/// Never runs on the main thread — a failed retry returns `Uint8List(0)`
/// rather than blocking the UI with a 3-7 s synchronous decode +
/// warp + encode on a 12 MP capture.
Future<Uint8List> _runOffThread(_ProcessPayload payload) async {
  try {
    return await Isolate.run(() => _processInIsolate(payload));
  } catch (e) {
    _log.w('isolate failed, retrying', {'error': e.toString()});
    try {
      return await Isolate.run(() => _processInIsolate(payload));
    } catch (e2, st2) {
      _log.e('isolate retry failed, degrading to empty',
          error: e2, stackTrace: st2);
      // Intentional: no main-thread fallback. Callers interpret
      // empty bytes as "decode failed" and leave the page on its
      // placeholder. Better than freezing the UI for seconds.
      return Uint8List(0);
    }
  }
}

/// Top-level isolate entry point. Returns the encoded JPEG or an empty
/// list on decode failure so the caller can log and fall back to the
/// raw file. Also exposed as the body reused inside `_runOffThread`.
Uint8List _processInIsolate(_ProcessPayload payload) {
  // IX.B.3 — the `image` package's `decodeImage` returns null for
  // most undecodable inputs but throws `RangeError` on empty /
  // truncated buffers (e.g. a 0-byte gallery pick). Catching here
  // keeps the contract: empty-return = "couldn't decode, degrade
  // gracefully" — the caller shows the page unprocessed.
  img.Image? decoded;
  try {
    decoded = img.decodeImage(payload.bytes);
  } catch (_) {
    return Uint8List(0);
  }
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

  out = _applyFilter(out, payload.filter,
      thresholdOffset: payload.thresholdOffset,
      magicScale: payload.magicScale);
  // Per-page fine-tune. Skipped when both knobs are at identity so
  // the common "filter only" path stays cheap. Brightness applies to
  // every filter; contrast skips bw since adaptive threshold has
  // already collapsed the image to {0, 255} and contrast would just
  // re-saturate the same pixels.
  if (payload.brightness != 0 ||
      (payload.contrast != 0 && payload.filter != ScanFilter.bw)) {
    out = img.adjustColor(
      out,
      brightness: 1.0 + payload.brightness * 0.5,
      contrast: payload.filter == ScanFilter.bw
          ? null
          : 1.0 + payload.contrast * 0.6,
    );
  }
  out = _fitLongEdge(out, payload.maxOutputEdge);

  return Uint8List.fromList(img.encodeJpg(out, quality: payload.jpegQuality));
}

bool _isFullRect(Corners c) => isNearIdentityRect(c);

/// Frame-independent tolerance — a drag of this magnitude on a 4000-px
/// page is 20 pixels, below the threshold where a warp is visually
/// distinguishable from the identity. VIII.20 tightened the tolerance
/// from 0.01 to 0.005 so the warp step drops on near-identity drags.
/// Inclusive so a drag of exactly [kFullRectTolerance] still counts as
/// identity and skips the warp.
@visibleForTesting
bool isNearIdentityRect(Corners c) {
  const eps = kFullRectTolerance;
  return c.tl.x <= eps &&
      c.tl.y <= eps &&
      c.tr.x >= 1 - eps &&
      c.tr.y <= eps &&
      c.br.x >= 1 - eps &&
      c.br.y >= 1 - eps &&
      c.bl.x <= eps &&
      c.bl.y >= 1 - eps;
}

/// Tolerance under which `_isFullRect` short-circuits the warp step.
const double kFullRectTolerance = 0.005;

/// OpenCV-backed perspective warp. Builds the source-quad → axis-aligned
/// rectangle transform, runs `cv.warpPerspective` (native, multi-threaded
/// inside libopencv_imgproc), then copies the BGR output bytes back into
/// an `img.Image` so the rest of the pipeline can stay on the existing
/// pure-Dart filter chain.
///
/// In release builds only the native path is active — [perspectiveWarpDartFallback]
/// is excluded so the tree-shaker can eliminate the ~150 lines of pure-Dart
/// bilinear code. In debug and test builds the Dart fallback catches any FFI
/// failure (e.g. native library unavailable in the test runner).
img.Image _perspectiveWarp(img.Image src, Corners c) {
  if (kReleaseMode) {
    // Release: native only. If OpenCV fails here the scanner cannot
    // function regardless — the error is fatal rather than silently
    // producing the wrong output.
    return _perspectiveWarpOpenCv(src, c);
  }
  try {
    return _perspectiveWarpOpenCv(src, c);
  } catch (_) {
    return perspectiveWarpDartFallback(src, c);
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
///
/// Annotated `@visibleForTesting` because production code calls this only
/// through [_perspectiveWarp], which short-circuits to the native path in
/// release builds. Tests may call it directly to exercise the Dart path
/// without needing a native OpenCV library.
@visibleForTesting
img.Image perspectiveWarpDartFallback(img.Image src, Corners c) {
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

img.Image _applyFilter(
  img.Image src,
  ScanFilter filter, {
  double thresholdOffset = 0,
  double magicScale = 220,
}) {
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
      return binarizeWithOpenCv(src, cOffset: thresholdOffset) ??
          _adaptiveThreshold(img.grayscale(src));
    case ScanFilter.magicColor:
      return magicColorWithOpenCv(src, scale: magicScale) ?? _magicColor(src);
  }
}

/// Adaptive Gaussian threshold via opencv_dart. Pipeline:
///
///   1. cv.cvtColor BGR → GRAY
///   2. Unsharp pre-pass: gray + 1.0 × (gray − blur(gray)). Recovers
///      thin strokes that the threshold's local-mean window would
///      otherwise smear into the background.
///   3. cv.adaptiveThreshold with a 31×31 Gaussian window. The
///      C-value defaults to 8 and is shifted by [cOffset] (clamped
///      to ±30) so the per-page Tune slider can fix a too-dark or
///      too-faded result without changing the filter.
///
/// Returns null on FFI failure so the caller can fall back to the
/// pure-Dart integral-image path. Public so tests can exercise the
/// filter without going through the path_provider-dependent
/// `ScanImageProcessor.process()`.
img.Image? binarizeWithOpenCv(img.Image src, {double cOffset = 0}) {
  cv.Mat? srcMat;
  cv.Mat? gray;
  cv.Mat? blur;
  cv.Mat? sharp;
  cv.Mat? bin;
  try {
    final w = src.width;
    final h = src.height;
    final flat = src.convert(numChannels: 3)
        .getBytes(order: img.ChannelOrder.bgr);
    srcMat = cv.Mat.fromList(h, w, cv.MatType.CV_8UC3, flat);
    gray = cv.cvtColor(srcMat, cv.COLOR_BGR2GRAY);
    // Unsharp mask: blur the grayscale, then add the high-frequency
    // residual back at 1.0× weight. cv.addWeighted does
    // gray * (1 + amount) - blur * amount, sharp = gray + (gray - blur).
    blur = cv.gaussianBlur(gray, (5, 5), 0);
    sharp = cv.addWeighted(gray, 1.6, blur, -0.6, 0);
    final c = (8 + cOffset).clamp(-30.0, 30.0);
    bin = cv.adaptiveThreshold(
      sharp,
      255,
      cv.ADAPTIVE_THRESH_GAUSSIAN_C,
      cv.THRESH_BINARY,
      31, // odd block size — wide enough for text strokes, narrow
          // enough to track lighting gradients.
      c,  // C subtracted from the mean. Tune slider can shift this
          // to ±30 so users can fix overly aggressive / faint output
          // without leaving the scanner.
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
    blur?.dispose();
    sharp?.dispose();
    bin?.dispose();
  }
}

/// Magic colour via opencv_dart — multi-scale Retinex (MSR).
///
/// Pipeline:
///   1. Three Gaussian blurs at long-edge / 4, / 8 and / 16 capture
///      illumination at three frequencies (broad shadow gradient,
///      mid-scale lighting falloff, fine vignette).
///   2. Per-channel divide gives the reflectance estimate at each
///      scale.
///   3. Equal-weighted blend (avg of the three scales) gives the MSR
///      output. Single-scale Retinex (the previous one-blur approach)
///      either lost detail at large scales or kept too much shadow at
///      small scales — averaging recovers both.
///   4. Final contrast / saturation pop keeps the image punchy and
///      brightness +2 % opens shadows without blowing highlights.
///
/// Returns null on FFI failure so the caller can fall back to the
/// pure-Dart magic-color path.
img.Image? magicColorWithOpenCv(img.Image src, {double scale = 220}) {
  cv.Mat? srcMat;
  cv.Mat? srcF;
  cv.Mat? blur1;
  cv.Mat? blur2;
  cv.Mat? blur3;
  cv.Mat? blurF1;
  cv.Mat? blurF2;
  cv.Mat? blurF3;
  cv.Mat? norm1;
  cv.Mat? norm2;
  cv.Mat? norm3;
  cv.Mat? sum12;
  cv.Mat? sum123;
  cv.Mat? out8;
  try {
    final w = src.width;
    final h = src.height;
    final flat = src.convert(numChannels: 3)
        .getBytes(order: img.ChannelOrder.bgr);
    srcMat = cv.Mat.fromList(h, w, cv.MatType.CV_8UC3, flat);
    final longEdge = math.max(w, h);
    int oddK(int v) {
      var k = v;
      if (k.isEven) k += 1;
      return math.max(31, k);
    }
    final k1 = oddK((longEdge / 4).round());
    final k2 = oddK((longEdge / 8).round());
    final k3 = oddK((longEdge / 16).round());
    blur1 = cv.gaussianBlur(srcMat, (k1, k1), 0);
    blur2 = cv.gaussianBlur(srcMat, (k2, k2), 0);
    blur3 = cv.gaussianBlur(srcMat, (k3, k3), 0);
    srcF = srcMat.convertTo(cv.MatType.CV_32FC3);
    blurF1 = blur1.convertTo(cv.MatType.CV_32FC3);
    blurF2 = blur2.convertTo(cv.MatType.CV_32FC3);
    blurF3 = blur3.convertTo(cv.MatType.CV_32FC3);
    // Per-scale reflectance: scaled so the page background lifts
    // toward white without clipping. VIII.19 lifted [scale] from a
    // hard-coded 220 to a per-page param; range 180-240 maps to
    // "subtle" → "aggressive" illumination normalisation.
    norm1 = cv.divide(srcF, blurF1, scale: scale);
    norm2 = cv.divide(srcF, blurF2, scale: scale);
    norm3 = cv.divide(srcF, blurF3, scale: scale);
    // Average the three scales: MSR = (R1 + R2 + R3) / 3.
    sum12 = cv.addWeighted(norm1, 0.5, norm2, 0.5, 0);
    sum123 = cv.addWeighted(sum12, 2.0 / 3.0, norm3, 1.0 / 3.0, 0);
    out8 = sum123.convertTo(cv.MatType.CV_8UC3);
    final outBytes = Uint8List.fromList(out8.data);
    final lifted = img.Image.fromBytes(
      width: w,
      height: h,
      bytes: outBytes.buffer,
      order: img.ChannelOrder.bgr,
      numChannels: 3,
    );
    return img.adjustColor(lifted,
        contrast: 1.15, saturation: 1.15, brightness: 1.02);
  } catch (_) {
    return null;
  } finally {
    srcMat?.dispose();
    srcF?.dispose();
    blur1?.dispose();
    blur2?.dispose();
    blur3?.dispose();
    blurF1?.dispose();
    blurF2?.dispose();
    blurF3?.dispose();
    norm1?.dispose();
    norm2?.dispose();
    norm3?.dispose();
    sum12?.dispose();
    sum123?.dispose();
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
