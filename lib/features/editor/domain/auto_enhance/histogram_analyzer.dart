import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart' show compute, visibleForTesting;

import '../../../../core/logging/app_logger.dart';
import 'histogram_stats.dart';

final _log = AppLogger('Histogram');

/// Reads a [ui.Image], downsamples to ~256 px on the long edge so the
/// pass is fast even on 24-MP photos, and returns [HistogramStats].
///
/// ## Phase VI.4 — compute() pixel loop
///
/// The engine-bound steps (`_downscale` uses `PictureRecorder` +
/// `Picture.toImage`; `toByteData` marshals GPU→CPU) stay on the
/// calling isolate because they require the UI thread. The pure-Dart
/// pixel-binning loop + percentile math (cheap per pixel, but 65k
/// iterations on a 256×256 proxy adds up on mid-range Android) now
/// runs in a [compute] worker via [analyzeInIsolate].
///
/// The sync-loop [analyze] method stays as the ground truth: it runs
/// the same pixel loop on the current isolate so tests can drive it
/// without spawning. Both paths share a single pure helper
/// ([computeHistogramFromPixels]) so there's no chance the two
/// implementations silently drift apart — an equivalence test pins
/// that they return byte-identical bins + doubles.
class HistogramAnalyzer {
  const HistogramAnalyzer({this.targetLongEdge = 256});

  final int targetLongEdge;

  /// Run the histogram pass end-to-end on the current isolate. Engine-
  /// bound prep (downscale + `toByteData`) happens on main; the pixel
  /// loop runs synchronously after. Kept for tests and for call sites
  /// that explicitly want no isolate-spawn overhead.
  Future<HistogramStats?> analyze(ui.Image src) async {
    final sw = Stopwatch()..start();
    final extracted = await _extractPixels(src);
    if (extracted == null) return null;
    final stats = computeHistogramFromPixels(HistogramComputeArgs(
      pixels: extracted.pixels,
      width: extracted.width,
      height: extracted.height,
    ));
    extracted.disposeOwned();
    _log.d('analyzed', {
      ...stats.summary(),
      'ms': sw.elapsedMilliseconds,
    });
    return stats;
  }

  /// Phase VI.4: same contract as [analyze] but the pixel-binning +
  /// percentile math runs in a `compute()` isolate. Engine-bound prep
  /// (`_downscale` + `toByteData`) still runs on the calling isolate
  /// — those steps require the UI thread. Use this from the editor
  /// hot path (`EditorSession.applyAuto`) so the one-shot analysis
  /// doesn't freeze the UI during a slider-animated commit.
  ///
  /// Each call spawns a fresh isolate (~5–10 ms on Android). The
  /// caller is expected to be one-shot — `applyAuto` fires once per
  /// user tap — so the spawn cost amortises over a single analysis
  /// rather than paying it every frame (the way a slider drag would).
  Future<HistogramStats?> analyzeInIsolate(ui.Image src) async {
    final sw = Stopwatch()..start();
    final extracted = await _extractPixels(src);
    if (extracted == null) return null;
    _debugIsolateSpawnCount++;
    final stats = await compute(
      computeHistogramFromPixels,
      HistogramComputeArgs(
        pixels: extracted.pixels,
        width: extracted.width,
        height: extracted.height,
      ),
    );
    extracted.disposeOwned();
    _log.d('analyzed (isolate)', {
      ...stats.summary(),
      'ms': sw.elapsedMilliseconds,
    });
    return stats;
  }

  /// Test-observable counter: how many times [analyzeInIsolate]
  /// actually invoked `compute()`. Tests assert this grows by one on
  /// the isolate path and stays put on the sync path.
  static int _debugIsolateSpawnCount = 0;

  @visibleForTesting
  static int get debugIsolateSpawnCount => _debugIsolateSpawnCount;

  @visibleForTesting
  static void debugResetIsolateSpawnCount() {
    _debugIsolateSpawnCount = 0;
  }

  /// Downscale (if needed), pull the RGBA bytes off the GPU, and
  /// package everything into a small record. Returns null only when
  /// `toByteData` itself fails.
  Future<_ExtractedPixels?> _extractPixels(ui.Image src) async {
    final (small, ownsSmall) = await _downscale(src);
    final bytes = await small.toByteData(format: ui.ImageByteFormat.rawRgba);
    if (bytes == null) {
      _log.w('toByteData returned null');
      if (ownsSmall) small.dispose();
      return null;
    }
    return _ExtractedPixels(
      pixels: bytes.buffer.asUint8List(),
      width: small.width,
      height: small.height,
      owned: ownsSmall ? small : null,
    );
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
}

/// Bundle of the engine-extracted pixel bytes + dimensions + an
/// optional dispose callback for a downscaled copy.
class _ExtractedPixels {
  _ExtractedPixels({
    required this.pixels,
    required this.width,
    required this.height,
    required ui.Image? owned,
  }) : _owned = owned;

  final Uint8List pixels;
  final int width;
  final int height;
  final ui.Image? _owned;

  void disposeOwned() {
    _owned?.dispose();
  }
}

/// Isolate-sendable arg bundle for [computeHistogramFromPixels].
///
/// Must contain only types that cross `compute()`'s isolate boundary
/// without surprises: `Uint8List` (fast-path transfer) + two `int`s.
class HistogramComputeArgs {
  const HistogramComputeArgs({
    required this.pixels,
    required this.width,
    required this.height,
  });

  /// Raw RGBA bytes. Length must equal `width * height * 4`.
  final Uint8List pixels;
  final int width;
  final int height;
}

/// Phase VI.4 pure helper — bins pixels, computes percentiles,
/// assembles [HistogramStats]. Top-level (not a method) so `compute()`
/// can hand it to a worker isolate. Exposed both to the isolate path
/// ([HistogramAnalyzer.analyzeInIsolate]) and to equivalence tests
/// that pin the isolate output against a main-isolate reference run.
///
/// Contract: all fields of the returned stats are derived from the
/// [args.pixels] buffer; no I/O, no global state, no engine calls.
HistogramStats computeHistogramFromPixels(HistogramComputeArgs args) {
  final pixels = args.pixels;
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

  // Guard against an empty buffer (n == 0). The caller only ever
  // passes non-empty RGBA, but a zero-size input would divide by
  // zero; returning a deterministic all-zero stats block is friendlier
  // than throwing.
  if (n == 0) {
    return HistogramStats(
      rHist: rHist,
      gHist: gHist,
      bHist: bHist,
      lumHist: lumHist,
      rMean: 0,
      gMean: 0,
      bMean: 0,
      lumMean: 0,
      lumMedian: 0,
      lum1: 0,
      lum99: 0,
      r99: 0,
      g99: 0,
      b99: 0,
      lowKeyFraction: 0,
      highKeyFraction: 0,
      saturationMean: 0,
      sampleCount: 0,
    );
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

  return HistogramStats(
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
