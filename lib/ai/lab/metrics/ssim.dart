/// XVI.95a — Structural Similarity Index (SSIM).
///
/// Reference: Wang, Bovik, Sheikh & Simoncelli (2004). Implementation
/// follows the standard luminance/contrast/structure decomposition
/// with constants `C1 = (0.01 * L)^2` and `C2 = (0.03 * L)^2` for
/// `L = 255` (8-bit images). A non-overlapping 8×8 window is used in
/// place of the canonical 11×11 Gaussian — same calibration target
/// for the metric the lab actually uses (catching "did the AI op
/// soften a sharp image"), much cheaper to compute, and well-aligned
/// with the rule-of-thumb thresholds in the strategy doc.
///
/// The fast 8×8 box-window variant lands well within ~0.01 of the
/// canonical implementation on natural photos. We treat the metric as
/// a stability signal, not a perceptual oracle — for that we use
/// LPIPS in Tier 2 on the device.
///
/// Inputs are RGBA `Uint8List` (alpha ignored) at the same
/// dimensions. The metric is computed per-channel and averaged.
library;

import 'dart:typed_data';

const double _c1 = 6.5025; // (0.01 * 255)^2
const double _c2 = 58.5225; // (0.03 * 255)^2
const int _windowSize = 8;

/// Compute SSIM between two RGBA buffers of the same dimensions.
///
/// Returns a score in `[-1, 1]` (typically in `[0, 1]` for natural
/// photos). 1.0 = identical, 0.0 = uncorrelated, negative = anti-
/// correlated. The lab uses thresholds like `>= 0.96` (near-identity)
/// and `>= 0.85` (restoration).
double computeSsim(
  Uint8List a,
  Uint8List b, {
  required int width,
  required int height,
}) {
  if (a.length != b.length) {
    throw ArgumentError(
      'SSIM buffers must match: a=${a.length} b=${b.length}',
    );
  }
  if (a.length != width * height * 4) {
    throw ArgumentError(
      'SSIM buffer size ${a.length} != $width * $height * 4',
    );
  }
  if (width < _windowSize || height < _windowSize) {
    return _ssimSingleWindow(a, b, 0, 0, width, height, width);
  }
  double sum = 0;
  int windows = 0;
  for (var y = 0; y + _windowSize <= height; y += _windowSize) {
    for (var x = 0; x + _windowSize <= width; x += _windowSize) {
      sum += _ssimSingleWindow(a, b, x, y, _windowSize, _windowSize, width);
      windows++;
    }
  }
  return windows == 0 ? 0 : sum / windows;
}

/// SSIM contribution from a single window, averaged across R/G/B.
double _ssimSingleWindow(
  Uint8List a,
  Uint8List b,
  int x0,
  int y0,
  int w,
  int h,
  int stride,
) {
  double sum = 0;
  for (var c = 0; c < 3; c++) {
    sum += _ssimSingleChannel(a, b, x0, y0, w, h, stride, c);
  }
  return sum / 3;
}

/// Wang et al. SSIM formula on a single channel within a window.
double _ssimSingleChannel(
  Uint8List a,
  Uint8List b,
  int x0,
  int y0,
  int w,
  int h,
  int stride,
  int channel,
) {
  double sumA = 0, sumB = 0;
  double sumAA = 0, sumBB = 0, sumAB = 0;
  final n = w * h;
  for (var dy = 0; dy < h; dy++) {
    final row = (y0 + dy) * stride * 4;
    for (var dx = 0; dx < w; dx++) {
      final idx = row + (x0 + dx) * 4 + channel;
      final pa = a[idx].toDouble();
      final pb = b[idx].toDouble();
      sumA += pa;
      sumB += pb;
      sumAA += pa * pa;
      sumBB += pb * pb;
      sumAB += pa * pb;
    }
  }
  final muA = sumA / n;
  final muB = sumB / n;
  final varA = sumAA / n - muA * muA;
  final varB = sumBB / n - muB * muB;
  final covAB = sumAB / n - muA * muB;
  final num = (2 * muA * muB + _c1) * (2 * covAB + _c2);
  final den = (muA * muA + muB * muB + _c1) * (varA + varB + _c2);
  return den == 0 ? 1 : num / den;
}
