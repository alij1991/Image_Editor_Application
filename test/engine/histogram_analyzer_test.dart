import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';

import 'package:image_editor/features/editor/domain/auto_enhance/histogram_analyzer.dart';
import 'package:image_editor/features/editor/domain/auto_enhance/histogram_stats.dart';

/// Phase VI.4 — HistogramAnalyzer contract + compute() equivalence.
///
/// Two things to pin:
/// 1. [computeHistogramFromPixels] is a pure function: same input →
///    same output, byte-identical across the isolate boundary. If the
///    sync [HistogramAnalyzer.analyze] path and the compute-backed
///    [HistogramAnalyzer.analyzeInIsolate] path ever drift, that's a
///    latent off-main bug. The equivalence test binds them both.
/// 2. The isolate spawn actually happens for the async variant and
///    NOT for the sync variant. `debugIsolateSpawnCount` is the
///    observable hook.
///
/// Auto-enhance correctness (AutoEnhanceAnalyzer / AutoSectionAnalyzer)
/// is out of scope here — those are pure on `HistogramStats` and don't
/// touch the compute boundary. This file covers only the pixel-loop
/// layer VI.4 changed.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(HistogramAnalyzer.debugResetIsolateSpawnCount);

  /// Build a tiny `ui.Image` from a Uint8List of RGBA pixels.
  /// `decodeImageFromPixels` is the main-isolate-safe path.
  Future<ui.Image> imageFromBytes(int w, int h, Uint8List pixels) async {
    final completer = Completer<ui.Image>();
    ui.decodeImageFromPixels(
      pixels,
      w,
      h,
      ui.PixelFormat.rgba8888,
      completer.complete,
    );
    return completer.future;
  }

  /// Fill a w×h RGBA buffer with a single constant colour.
  Uint8List solidRgba(int w, int h, int r, int g, int b) {
    final bytes = Uint8List(w * h * 4);
    for (int i = 0; i < w * h; i++) {
      bytes[i * 4 + 0] = r;
      bytes[i * 4 + 1] = g;
      bytes[i * 4 + 2] = b;
      bytes[i * 4 + 3] = 255;
    }
    return bytes;
  }

  /// Fill a w×h RGBA buffer with a vertical luminance ramp (top rows
  /// black, bottom rows white). Good for exercising percentiles.
  Uint8List verticalRamp(int w, int h) {
    final bytes = Uint8List(w * h * 4);
    for (int y = 0; y < h; y++) {
      final v = (y * 255 / (h - 1)).round();
      for (int x = 0; x < w; x++) {
        final i = (y * w + x) * 4;
        bytes[i + 0] = v;
        bytes[i + 1] = v;
        bytes[i + 2] = v;
        bytes[i + 3] = 255;
      }
    }
    return bytes;
  }

  void expectStatsClose(
    HistogramStats a,
    HistogramStats b, {
    double tolerance = 1e-9,
  }) {
    expect(a.sampleCount, b.sampleCount);
    expect(a.rHist, b.rHist);
    expect(a.gHist, b.gHist);
    expect(a.bHist, b.bHist);
    expect(a.lumHist, b.lumHist);
    expect(a.rMean, closeTo(b.rMean, tolerance));
    expect(a.gMean, closeTo(b.gMean, tolerance));
    expect(a.bMean, closeTo(b.bMean, tolerance));
    expect(a.lumMean, closeTo(b.lumMean, tolerance));
    expect(a.lumMedian, closeTo(b.lumMedian, tolerance));
    expect(a.lum1, closeTo(b.lum1, tolerance));
    expect(a.lum99, closeTo(b.lum99, tolerance));
    expect(a.r99, closeTo(b.r99, tolerance));
    expect(a.g99, closeTo(b.g99, tolerance));
    expect(a.b99, closeTo(b.b99, tolerance));
    expect(a.lowKeyFraction, closeTo(b.lowKeyFraction, tolerance));
    expect(a.highKeyFraction, closeTo(b.highKeyFraction, tolerance));
    expect(a.saturationMean, closeTo(b.saturationMean, tolerance));
  }

  group('computeHistogramFromPixels (pure helper)', () {
    test('solid mid-grey produces symmetric histograms', () {
      const w = 8;
      const h = 8;
      final bytes = solidRgba(w, h, 128, 128, 128);
      final stats = computeHistogramFromPixels(
        HistogramComputeArgs(pixels: bytes, width: w, height: h),
      );
      expect(stats.sampleCount, w * h);
      expect(stats.rHist[128], w * h);
      expect(stats.gHist[128], w * h);
      expect(stats.bHist[128], w * h);
      // rMean, gMean, bMean for solid 128 are 128/255 ≈ 0.502.
      expect(stats.rMean, closeTo(128 / 255, 1e-9));
      expect(stats.lumMean, closeTo(128 / 255, 1e-9));
      // Solid grey → zero saturation.
      expect(stats.saturationMean, 0.0);
      // No clipping.
      expect(stats.lowKeyFraction, 0.0);
      expect(stats.highKeyFraction, 0.0);
    });

    test('solid black registers as low-key clipping', () {
      const w = 4;
      const h = 4;
      final bytes = solidRgba(w, h, 0, 0, 0);
      final stats = computeHistogramFromPixels(
        HistogramComputeArgs(pixels: bytes, width: w, height: h),
      );
      expect(stats.lowKeyFraction, 1.0);
      expect(stats.highKeyFraction, 0.0);
      expect(stats.lumMean, 0.0);
      expect(stats.lumHist[0], w * h);
    });

    test('solid white registers as high-key clipping', () {
      const w = 4;
      const h = 4;
      final bytes = solidRgba(w, h, 255, 255, 255);
      final stats = computeHistogramFromPixels(
        HistogramComputeArgs(pixels: bytes, width: w, height: h),
      );
      expect(stats.highKeyFraction, 1.0);
      expect(stats.lowKeyFraction, 0.0);
      expect(stats.lumMean, 1.0);
      expect(stats.lumHist[255], w * h);
    });

    test('saturated red has non-zero saturation', () {
      const w = 4;
      const h = 4;
      final bytes = solidRgba(w, h, 255, 0, 0);
      final stats = computeHistogramFromPixels(
        HistogramComputeArgs(pixels: bytes, width: w, height: h),
      );
      // HSV sat for pure red (max=255, min=0) = 1.0.
      expect(stats.saturationMean, 1.0);
    });

    test('vertical luminance ramp spreads histogram across all bins', () {
      // 256 rows so every luminance 0..255 is hit exactly once per col.
      const w = 4;
      const h = 256;
      final bytes = verticalRamp(w, h);
      final stats = computeHistogramFromPixels(
        HistogramComputeArgs(pixels: bytes, width: w, height: h),
      );
      // Every bin should have exactly `w` entries (4).
      expect(stats.lumHist.every((c) => c == w), isTrue);
      // 99th percentile should be very near white.
      expect(stats.lum99, greaterThan(0.95));
      // 1st percentile near black.
      expect(stats.lum1, lessThan(0.05));
      // Mean ≈ 0.5.
      expect(stats.lumMean, closeTo(0.5, 0.01));
    });

    test('empty buffer returns zero-sample stats without dividing by zero',
        () {
      final stats = computeHistogramFromPixels(
        HistogramComputeArgs(
          pixels: Uint8List(0),
          width: 0,
          height: 0,
        ),
      );
      expect(stats.sampleCount, 0);
      expect(stats.lumMean, 0);
      expect(stats.saturationMean, 0);
      // Histograms stay zeroed.
      expect(stats.rHist.every((c) => c == 0), isTrue);
    });

    test('alpha channel is ignored (fully-transparent pixels still count)',
        () {
      const w = 2;
      const h = 2;
      final bytes = Uint8List(w * h * 4);
      for (int i = 0; i < w * h; i++) {
        bytes[i * 4 + 0] = 200;
        bytes[i * 4 + 1] = 100;
        bytes[i * 4 + 2] = 50;
        bytes[i * 4 + 3] = 0; // fully transparent
      }
      final stats = computeHistogramFromPixels(
        HistogramComputeArgs(pixels: bytes, width: w, height: h),
      );
      expect(stats.rHist[200], w * h);
      expect(stats.gHist[100], w * h);
      expect(stats.bHist[50], w * h);
    });
  });

  group('HistogramAnalyzer.analyze (sync) vs analyzeInIsolate', () {
    test('sync path does not spawn an isolate', () async {
      final img = await imageFromBytes(4, 4, solidRgba(4, 4, 100, 150, 200));
      final before = HistogramAnalyzer.debugIsolateSpawnCount;
      final stats = await const HistogramAnalyzer().analyze(img);
      expect(stats, isNotNull);
      expect(HistogramAnalyzer.debugIsolateSpawnCount, before);
      img.dispose();
    });

    test('isolate path increments the spawn counter exactly once', () async {
      final img = await imageFromBytes(4, 4, solidRgba(4, 4, 100, 150, 200));
      final before = HistogramAnalyzer.debugIsolateSpawnCount;
      final stats = await const HistogramAnalyzer().analyzeInIsolate(img);
      expect(stats, isNotNull);
      expect(HistogramAnalyzer.debugIsolateSpawnCount, before + 1);
      img.dispose();
    });

    test('sync and isolate paths return byte-identical HistogramStats '
        'for the same image', () async {
      const w = 16;
      const h = 16;
      // Procedurally generate a non-trivial image so histograms,
      // percentiles, and saturation all have something to bite.
      final bytes = Uint8List(w * h * 4);
      for (int y = 0; y < h; y++) {
        for (int x = 0; x < w; x++) {
          final i = (y * w + x) * 4;
          bytes[i + 0] = (x * 16).clamp(0, 255);
          bytes[i + 1] = (y * 16).clamp(0, 255);
          bytes[i + 2] = ((x + y) * 8).clamp(0, 255);
          bytes[i + 3] = 255;
        }
      }
      final img = await imageFromBytes(w, h, bytes);
      try {
        const analyzer = HistogramAnalyzer();
        final syncStats = await analyzer.analyze(img);
        final isoStats = await analyzer.analyzeInIsolate(img);
        expect(syncStats, isNotNull);
        expect(isoStats, isNotNull);
        expectStatsClose(syncStats!, isoStats!);
      } finally {
        img.dispose();
      }
    });

    test('analyze on an image bigger than targetLongEdge still works '
        '(downscale path)', () async {
      // Push above the default target (256). Use a uniform fill so
      // downscaling is irrelevant to content — we just need to be
      // sure the downscale branch is exercised without crashing.
      const w = 512;
      const h = 512;
      final img = await imageFromBytes(w, h, solidRgba(w, h, 50, 80, 110));
      try {
        final stats = await const HistogramAnalyzer().analyzeInIsolate(img);
        expect(stats, isNotNull);
        // targetLongEdge=256 → downscaled to 256x256 = 65_536 samples.
        expect(stats!.sampleCount, 256 * 256);
        // Colour stays roughly the same after downscale.
        expect(stats.rMean, closeTo(50 / 255, 0.05));
      } finally {
        img.dispose();
      }
    });

    test('analyze on an image at or below targetLongEdge skips the '
        'downscale (uses source dimensions)', () async {
      const w = 64;
      const h = 48;
      final img = await imageFromBytes(w, h, solidRgba(w, h, 200, 200, 200));
      try {
        final stats = await const HistogramAnalyzer().analyze(img);
        expect(stats, isNotNull);
        expect(stats!.sampleCount, w * h);
      } finally {
        img.dispose();
      }
    });
  });
}

