/// Compact statistics over a downscaled source image, shared by every
/// auto-fix analyser (auto-enhance, per-section auto, auto white
/// balance).
///
/// All values are in 0..1 normalized units. Histograms are 256 bins.
class HistogramStats {
  const HistogramStats({
    required this.rHist,
    required this.gHist,
    required this.bHist,
    required this.lumHist,
    required this.rMean,
    required this.gMean,
    required this.bMean,
    required this.lumMean,
    required this.lumMedian,
    required this.lum1,
    required this.lum99,
    required this.r99,
    required this.g99,
    required this.b99,
    required this.lowKeyFraction,
    required this.highKeyFraction,
    required this.saturationMean,
    required this.sampleCount,
  });

  /// Per-channel histograms (256 bins, each entry is the count in that bin).
  final List<int> rHist;
  final List<int> gHist;
  final List<int> bHist;

  /// Luminance histogram (Rec. 709 weights) — 256 bins.
  final List<int> lumHist;

  /// Mean of each channel, normalized 0..1.
  final double rMean;
  final double gMean;
  final double bMean;

  /// Mean and median luminance, normalized 0..1.
  final double lumMean;
  final double lumMedian;

  /// 1st and 99th percentile luminance, normalized 0..1.
  /// These drive highlight/shadow recovery and contrast decisions.
  final double lum1;
  final double lum99;

  /// 99th percentile of each channel — used by the white-patch estimate
  /// for auto white balance.
  final double r99;
  final double g99;
  final double b99;

  /// Fraction of pixels below 0.1 luminance (shadow heaviness) and above
  /// 0.9 (highlight heaviness). Inform shadow/highlight auto-corrections.
  final double lowKeyFraction;
  final double highKeyFraction;

  /// Mean HSV saturation, 0..1. Low values → the image is desaturated;
  /// high values → vibrance boost would be redundant.
  final double saturationMean;

  final int sampleCount;

  Map<String, dynamic> summary() => {
        'lumMean': lumMean.toStringAsFixed(3),
        'lumMedian': lumMedian.toStringAsFixed(3),
        'lum1': lum1.toStringAsFixed(3),
        'lum99': lum99.toStringAsFixed(3),
        'r99': r99.toStringAsFixed(3),
        'g99': g99.toStringAsFixed(3),
        'b99': b99.toStringAsFixed(3),
        'satMean': saturationMean.toStringAsFixed(3),
        'lowKey': lowKeyFraction.toStringAsFixed(3),
        'highKey': highKeyFraction.toStringAsFixed(3),
        'samples': sampleCount,
      };
}
