/// XVI.95a — Laplacian variance (no-reference sharpness measure).
///
/// Convolves the input with the discrete Laplacian kernel
/// `[[0, 1, 0], [1, -4, 1], [0, 1, 0]]` and returns the variance of
/// the result. Higher variance = more high-frequency content = sharper
/// image. Standard focus-measure metric (Pech-Pacheco et al. 2000)
/// also used by OpenCV's `cv2.Laplacian(...).var()` pattern.
///
/// Used as the reference-free guard for AI Deblur:
///
/// - Deblur on a SHARP input must NOT reduce variance.
/// - Deblur on a BLURRY input should ideally raise it (the lab uses
///   `Δ >= 1.3×` as the pass line per the strategy doc).
///
/// Operates on grayscale `Uint8List`. RGBA input must be reduced
/// first via [rgbaToLuma].
library;

import 'dart:typed_data';

/// ITU-R BT.709 luma reduction of an RGBA buffer to single-channel
/// `Uint8List`. The Laplacian metric is luma-only because chroma
/// noise inflates the variance without reflecting real sharpness.
Uint8List rgbaToLuma(Uint8List rgba) {
  if (rgba.length % 4 != 0) {
    throw ArgumentError(
      'rgba length must be a multiple of 4, got ${rgba.length}',
    );
  }
  final out = Uint8List(rgba.length ~/ 4);
  for (var i = 0, j = 0; i < rgba.length; i += 4, j++) {
    final r = rgba[i];
    final g = rgba[i + 1];
    final b = rgba[i + 2];
    // BT.709: 0.2126R + 0.7152G + 0.0722B, scaled by 1024 to stay
    // in integer arithmetic without a divide.
    final y = (218 * r + 732 * g + 74 * b + 512) >> 10;
    out[j] = y > 255 ? 255 : y;
  }
  return out;
}

/// Compute the variance of the discrete Laplacian over a grayscale
/// image of dimensions [width] × [height].
///
/// The 1-pixel border is excluded from both the convolution and the
/// variance sum (no zero-padding) so the metric isn't distorted by
/// the edge of the frame. For images < 3×3 returns 0.
double computeLaplacianVariance(
  Uint8List gray, {
  required int width,
  required int height,
}) {
  if (gray.length != width * height) {
    throw ArgumentError(
      'gray buffer size ${gray.length} != $width * $height',
    );
  }
  if (width < 3 || height < 3) return 0;
  final stride = width;
  final interiorCount = (width - 2) * (height - 2);
  // First pass: compute mean of the Laplacian over interior pixels.
  double sum = 0;
  for (var y = 1; y < height - 1; y++) {
    for (var x = 1; x < width - 1; x++) {
      final c = gray[y * stride + x];
      final n = gray[(y - 1) * stride + x];
      final s = gray[(y + 1) * stride + x];
      final w = gray[y * stride + (x - 1)];
      final e = gray[y * stride + (x + 1)];
      final lap = (n + s + w + e) - 4 * c;
      sum += lap;
    }
  }
  final mean = sum / interiorCount;
  // Second pass: variance.
  double sumSq = 0;
  for (var y = 1; y < height - 1; y++) {
    for (var x = 1; x < width - 1; x++) {
      final c = gray[y * stride + x];
      final n = gray[(y - 1) * stride + x];
      final s = gray[(y + 1) * stride + x];
      final w = gray[y * stride + (x - 1)];
      final e = gray[y * stride + (x + 1)];
      final lap = (n + s + w + e) - 4 * c;
      final d = lap - mean;
      sumSq += d * d;
    }
  }
  return sumSq / interiorCount;
}
