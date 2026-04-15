import 'dart:math' as math;
import 'dart:ui' as ui;

import '../../../../core/logging/app_logger.dart';
import 'histogram_stats.dart';

final _log = AppLogger('Histogram');

/// Reads a [ui.Image], downsamples to ~256 px on the long edge so the
/// pass is fast even on 24-MP photos, and returns [HistogramStats].
class HistogramAnalyzer {
  const HistogramAnalyzer({this.targetLongEdge = 256});

  final int targetLongEdge;

  Future<HistogramStats?> analyze(ui.Image src) async {
    final sw = Stopwatch()..start();
    final (small, ownsSmall) = await _downscale(src);
    final bytes = await small.toByteData(format: ui.ImageByteFormat.rawRgba);
    if (bytes == null) {
      _log.w('toByteData returned null');
      if (ownsSmall) small.dispose();
      return null;
    }
    final pixels = bytes.buffer.asUint8List();
    final rHist = List<int>.filled(256, 0);
    final gHist = List<int>.filled(256, 0);
    final bHist = List<int>.filled(256, 0);
    final lumHist = List<int>.filled(256, 0);
    var rSum = 0, gSum = 0, bSum = 0, lumSum = 0;
    var satSum = 0.0;
    var lowKey = 0, highKey = 0;
    final n = pixels.length ~/ 4;
    for (var i = 0; i < pixels.length; i += 4) {
      final r = pixels[i];
      final g = pixels[i + 1];
      final b = pixels[i + 2];
      // Rec. 709 luminance.
      final lum = (0.2126 * r + 0.7152 * g + 0.0722 * b).round().clamp(0, 255);
      rHist[r]++;
      gHist[g]++;
      bHist[b]++;
      lumHist[lum]++;
      rSum += r;
      gSum += g;
      bSum += b;
      lumSum += lum;
      if (lum < 26) lowKey++;
      if (lum > 230) highKey++;
      // HSV saturation.
      final mx = math.max(r, math.max(g, b));
      if (mx != 0) {
        final mn = math.min(r, math.min(g, b));
        satSum += (mx - mn) / mx;
      }
    }

    final lumMean = (lumSum / n) / 255.0;
    final rMean = (rSum / n) / 255.0;
    final gMean = (gSum / n) / 255.0;
    final bMean = (bSum / n) / 255.0;

    final lumMedian = _percentile(lumHist, n, 0.50) / 255.0;
    final lum1 = _percentile(lumHist, n, 0.01) / 255.0;
    final lum99 = _percentile(lumHist, n, 0.99) / 255.0;
    final r99 = _percentile(rHist, n, 0.99) / 255.0;
    final g99 = _percentile(gHist, n, 0.99) / 255.0;
    final b99 = _percentile(bHist, n, 0.99) / 255.0;

    final stats = HistogramStats(
      rHist: rHist,
      gHist: gHist,
      bHist: bHist,
      lumHist: lumHist,
      rMean: rMean,
      gMean: gMean,
      bMean: bMean,
      lumMean: lumMean,
      lumMedian: lumMedian,
      lum1: lum1,
      lum99: lum99,
      r99: r99,
      g99: g99,
      b99: b99,
      lowKeyFraction: lowKey / n,
      highKeyFraction: highKey / n,
      saturationMean: satSum / n,
      sampleCount: n,
    );
    _log.d('analyzed', {
      ...stats.summary(),
      'ms': sw.elapsedMilliseconds,
    });
    // Only dispose if we actually allocated a downscaled copy — never
    // touch the caller's source image.
    if (ownsSmall) small.dispose();
    return stats;
  }

  /// Returns `(image, ownsIt)`. When [ownsIt] is true we allocated a
  /// downscaled copy that the caller must dispose. When false, the
  /// original image was small enough to use directly and must NOT be
  /// disposed by us.
  Future<(ui.Image, bool)> _downscale(ui.Image src) async {
    final longEdge = math.max(src.width, src.height);
    if (longEdge <= targetLongEdge) return (src, false);
    final scale = targetLongEdge / longEdge;
    final w = (src.width * scale).round();
    final h = (src.height * scale).round();
    final recorder = ui.PictureRecorder();
    final canvas = ui.Canvas(recorder);
    final srcRect = ui.Rect.fromLTWH(
      0,
      0,
      src.width.toDouble(),
      src.height.toDouble(),
    );
    final dstRect = ui.Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble());
    canvas.drawImageRect(src, srcRect, dstRect, ui.Paint());
    final picture = recorder.endRecording();
    final image = await picture.toImage(w, h);
    picture.dispose();
    return (image, true);
  }

  /// Returns the bin index such that the cumulative count reaches
  /// [fraction] * [total]. Used for robust percentile lookups.
  int _percentile(List<int> hist, int total, double fraction) {
    final target = (total * fraction).floor();
    var acc = 0;
    for (var i = 0; i < hist.length; i++) {
      acc += hist[i];
      if (acc >= target) return i;
    }
    return hist.length - 1;
  }
}
