import 'package:flutter_test/flutter_test.dart';

import 'package:image_editor/features/editor/domain/auto_enhance/auto_white_balance.dart';
import 'package:image_editor/features/editor/domain/auto_enhance/histogram_stats.dart';

/// Phase XVI.32 — pin the FFT-style log-chroma color constancy path
/// in `AutoWhiteBalance` and confirm the classical (gray-world +
/// white-patch) blend is preserved as the fallback.
///
/// The two-tier design is deliberate: log-chroma produces stronger
/// estimates on heavy-cast scenes (sunset, indoor amber) but degrades
/// to noise on near-monochrome / very flat histograms. The fallback
/// preserves pre-XVI.32 behaviour for those inputs.

const int _kN = HistogramStats.kLogChromaBins; // 32
const double _kR = HistogramStats.kLogChromaRange; // 2.0

/// Build a HistogramStats with everything zeroed out except the log-
/// chroma histogram (a single bright bin at the requested
/// `(uIdx, vIdx)`). Lets us drive the log-chroma path without
/// generating fake pixel data.
HistogramStats _statsWithLogChromaPeak({
  required int uIdx,
  required int vIdx,
  required int peakCount,
  required int spreadCount,
}) {
  final hist = List<int>.filled(_kN * _kN, spreadCount);
  hist[vIdx * _kN + uIdx] = peakCount;
  // sampleCount in the log-chroma grid is the sum.
  final lcSamples = hist.fold<int>(0, (a, b) => a + b);
  return HistogramStats(
    rHist: List<int>.filled(256, 0),
    gHist: List<int>.filled(256, 0),
    bHist: List<int>.filled(256, 0),
    lumHist: List<int>.filled(256, 0),
    logChromaHist: hist,
    logChromaSampleCount: lcSamples,
    rMean: 0.5,
    gMean: 0.5,
    bMean: 0.5,
    lumMean: 0.5,
    lumMedian: 0.5,
    lum1: 0.0,
    lum99: 1.0,
    r99: 1.0,
    g99: 1.0,
    b99: 1.0,
    lowKeyFraction: 0,
    highKeyFraction: 0,
    saturationMean: 0,
    sampleCount: 1024,
  );
}

/// Build a stats block that intentionally fails the log-chroma path:
/// either too few samples or a flat (low peak/mean ratio) histogram.
/// Drives the classical fallback.
HistogramStats _statsForClassical({
  required double rMean,
  required double gMean,
  required double bMean,
  double r99 = 1.0,
  double g99 = 1.0,
  double b99 = 1.0,
}) {
  return HistogramStats(
    rHist: List<int>.filled(256, 0),
    gHist: List<int>.filled(256, 0),
    bHist: List<int>.filled(256, 0),
    lumHist: List<int>.filled(256, 0),
    // Empty log-chroma histogram → log-chroma path bails on min-sample
    // check and falls through.
    logChromaHist: List<int>.filled(_kN * _kN, 0),
    logChromaSampleCount: 0,
    rMean: rMean,
    gMean: gMean,
    bMean: bMean,
    lumMean: (rMean + gMean + bMean) / 3,
    lumMedian: (rMean + gMean + bMean) / 3,
    lum1: 0.0,
    lum99: 1.0,
    r99: r99,
    g99: g99,
    b99: b99,
    lowKeyFraction: 0,
    highKeyFraction: 0,
    saturationMean: 0,
    sampleCount: 65536,
  );
}

/// Map a desired (u*, v*) in log2 units to a (uIdx, vIdx) bin pair.
/// Inverse of the binning in `histogram_analyzer.dart`.
({int u, int v}) _bin(double ustar, double vstar) {
  const scale = _kN / (2 * _kR);
  final uIdx = ((ustar + _kR) * scale).floor().clamp(0, _kN - 1);
  final vIdx = ((vstar + _kR) * scale).floor().clamp(0, _kN - 1);
  return (u: uIdx, v: vIdx);
}

void main() {
  group('AutoWhiteBalance log-chroma path (XVI.32)', () {
    test('warm cast (R/G high, B/G low) → cool temperature delta', () {
      // Image dominated by warm chroma: u* = +0.4 (R > G), v* = -0.4
      // (B < G). Auto-WB should pull temperature toward COOL (negative)
      // to neutralize.
      final p = _bin(0.4, -0.4);
      final stats = _statsWithLogChromaPeak(
        uIdx: p.u,
        vIdx: p.v,
        peakCount: 1000,
        spreadCount: 1,
      );
      const wb = AutoWhiteBalance(strength: 1.0, maxDelta: 1.0);
      final r = wb.analyze(stats);
      expect(r.temperatureDelta, lessThan(0),
          reason: 'warm cast must produce cool correction');
      // (v* - u*) / 0.6 = -0.8/0.6 ≈ -1.33 → clamped to -1.0
      expect(r.temperatureDelta, lessThanOrEqualTo(-0.8));
    });

    test('cool cast (B/G high, R/G low) → warm temperature delta', () {
      final p = _bin(-0.4, 0.4);
      final stats = _statsWithLogChromaPeak(
        uIdx: p.u,
        vIdx: p.v,
        peakCount: 1000,
        spreadCount: 1,
      );
      const wb = AutoWhiteBalance(strength: 1.0, maxDelta: 1.0);
      final r = wb.analyze(stats);
      expect(r.temperatureDelta, greaterThan(0),
          reason: 'cool cast must produce warm correction');
      expect(r.temperatureDelta, greaterThanOrEqualTo(0.8));
    });

    test('green cast (G > R, G > B) → magenta tint delta', () {
      // Image dominated by green: u* = -0.3 (R/G < 1), v* = -0.3
      // (B/G < 1). Auto-WB should produce POSITIVE tint (magenta) to
      // neutralize.
      final p = _bin(-0.3, -0.3);
      final stats = _statsWithLogChromaPeak(
        uIdx: p.u,
        vIdx: p.v,
        peakCount: 1000,
        spreadCount: 1,
      );
      const wb = AutoWhiteBalance(strength: 1.0, maxDelta: 1.0);
      final r = wb.analyze(stats);
      expect(r.tintDelta, greaterThan(0),
          reason: 'green cast must produce magenta correction');
    });

    test('magenta cast (R+B > G) → green tint delta', () {
      final p = _bin(0.3, 0.3);
      final stats = _statsWithLogChromaPeak(
        uIdx: p.u,
        vIdx: p.v,
        peakCount: 1000,
        spreadCount: 1,
      );
      const wb = AutoWhiteBalance(strength: 1.0, maxDelta: 1.0);
      final r = wb.analyze(stats);
      expect(r.tintDelta, lessThan(0),
          reason: 'magenta cast must produce green correction');
    });

    test('flat histogram (low peak/mean ratio) falls through to classical',
        () {
      // Spread the histogram uniformly — the peak/mean ratio is 1.0,
      // far below the 3.0 threshold, so log-chroma must bail.
      final stats = HistogramStats(
        rHist: List<int>.filled(256, 0),
        gHist: List<int>.filled(256, 0),
        bHist: List<int>.filled(256, 0),
        lumHist: List<int>.filled(256, 0),
        logChromaHist: List<int>.filled(_kN * _kN, 5),
        logChromaSampleCount: _kN * _kN * 5,
        // Drive classical fallback: warm-leaning means trigger
        // gray-world toward COOL temp.
        rMean: 0.6,
        gMean: 0.5,
        bMean: 0.4,
        lumMean: 0.5,
        lumMedian: 0.5,
        lum1: 0.0,
        lum99: 1.0,
        // Wide white-patch spread so it doesn't early-out.
        r99: 0.95,
        g99: 0.85,
        b99: 0.75,
        lowKeyFraction: 0,
        highKeyFraction: 0,
        saturationMean: 0.2,
        sampleCount: 65536,
      );
      const wb = AutoWhiteBalance(strength: 1.0, maxDelta: 1.0);
      final r = wb.analyze(stats);
      // Classical: gainR ≈ low (warm image), gainB ≈ high → tempRaw < 0.
      expect(r.temperatureDelta, lessThan(0));
    });

    test('too-few samples bails out of log-chroma', () {
      // 100 samples at a tight peak; below the 256 minimum.
      final p = _bin(0.4, -0.4);
      final hist = List<int>.filled(_kN * _kN, 0);
      hist[p.v * _kN + p.u] = 100;
      final stats = HistogramStats(
        rHist: List<int>.filled(256, 0),
        gHist: List<int>.filled(256, 0),
        bHist: List<int>.filled(256, 0),
        lumHist: List<int>.filled(256, 0),
        logChromaHist: hist,
        logChromaSampleCount: 100,
        // Classical falls through to "no cast" — wp spread is small.
        rMean: 0.5, gMean: 0.5, bMean: 0.5,
        lumMean: 0.5, lumMedian: 0.5, lum1: 0.0, lum99: 1.0,
        r99: 0.9, g99: 0.9, b99: 0.9,
        lowKeyFraction: 0, highKeyFraction: 0, saturationMean: 0,
        sampleCount: 1024,
      );
      const wb = AutoWhiteBalance(strength: 1.0, maxDelta: 1.0);
      final r = wb.analyze(stats);
      // Log-chroma path bails (too few samples) → classical bails
      // (wp spread too small) → both deltas zero.
      expect(r.temperatureDelta, 0);
      expect(r.tintDelta, 0);
    });

    test('strength=0 returns zero deltas regardless of cast', () {
      final p = _bin(0.4, -0.4);
      final stats = _statsWithLogChromaPeak(
        uIdx: p.u,
        vIdx: p.v,
        peakCount: 1000,
        spreadCount: 1,
      );
      const wb = AutoWhiteBalance(strength: 0.0, maxDelta: 1.0);
      final r = wb.analyze(stats);
      expect(r.temperatureDelta, 0);
      expect(r.tintDelta, 0);
    });

    test('maxDelta clamps wild casts to the safe range', () {
      // Pin a peak way out near the histogram edge so the raw delta
      // would exceed the 0.5 default cap.
      final p = _bin(1.5, -1.5);
      final stats = _statsWithLogChromaPeak(
        uIdx: p.u,
        vIdx: p.v,
        peakCount: 5000,
        spreadCount: 1,
      );
      const wb = AutoWhiteBalance(strength: 1.0, maxDelta: 0.5);
      final r = wb.analyze(stats);
      expect(r.temperatureDelta.abs(), lessThanOrEqualTo(0.5));
      expect(r.tintDelta.abs(), lessThanOrEqualTo(0.5));
    });
  });

  group('AutoWhiteBalance classical fallback (pre-XVI.32 behaviour)', () {
    test('neutral image returns zero deltas (wp spread too small)', () {
      // gray-world flat + white-patch flat = no cast detected.
      final stats = _statsForClassical(
        rMean: 0.5, gMean: 0.5, bMean: 0.5,
        r99: 0.9, g99: 0.9, b99: 0.9,
      );
      const wb = AutoWhiteBalance(strength: 1.0, maxDelta: 1.0);
      final r = wb.analyze(stats);
      expect(r.temperatureDelta, 0);
      expect(r.tintDelta, 0);
    });

    test('warm-cast classical input still pulls temp negative', () {
      // High-R / low-B with a real white-patch spread.
      final stats = _statsForClassical(
        rMean: 0.6, gMean: 0.5, bMean: 0.4,
        r99: 0.95, g99: 0.85, b99: 0.75,
      );
      const wb = AutoWhiteBalance(strength: 1.0, maxDelta: 1.0);
      final r = wb.analyze(stats);
      expect(r.temperatureDelta, lessThan(0));
    });
  });

  group('asPreset wires the analysed deltas into a Preset', () {
    test('non-trivial deltas produce ops; near-zero ones drop', () {
      final p = _bin(0.4, -0.4);
      final stats = _statsWithLogChromaPeak(
        uIdx: p.u,
        vIdx: p.v,
        peakCount: 1000,
        spreadCount: 1,
      );
      const wb = AutoWhiteBalance(strength: 1.0, maxDelta: 1.0);
      final preset = wb.asPreset(stats);
      expect(preset.id, 'auto.whiteBalance');
      // With this peak the temp delta is large; tint may be ≈ 0 and
      // get dropped by the 0.02 threshold.
      expect(preset.operations, isNotEmpty);
    });
  });
}
