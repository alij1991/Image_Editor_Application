/// XVI.95a — Peak Signal-to-Noise Ratio.
///
/// Standard formula `10 * log10(MAX^2 / MSE)`. Used for "did the
/// denoiser recover the clean reference" tests where we have a known
/// noise-free image to compare against. Higher is better; >30 dB is
/// the conventional "visually indistinguishable" line for photos.
///
/// Operates on either RGBA `Uint8List` (alpha ignored) or grayscale
/// `Uint8List`. Both buffers must have the same dimensions; the
/// caller is responsible for any resize.
library;

import 'dart:math' as math;
import 'dart:typed_data';

/// Mean squared error between two byte buffers.
///
/// If [stride] is 1 the buffers are treated as grayscale. If [stride]
/// is 4 they are treated as RGBA and only the R/G/B channels
/// contribute (alpha is ignored — denoise/sharpen never touch alpha).
double computeMse(
  Uint8List a,
  Uint8List b, {
  required int stride,
}) {
  assert(stride == 1 || stride == 4, 'stride must be 1 (gray) or 4 (rgba)');
  if (a.length != b.length) {
    throw ArgumentError(
      'PSNR buffers must match: a.length=${a.length} b.length=${b.length}',
    );
  }
  if (a.isEmpty) return 0;
  double sumSq = 0;
  int count = 0;
  if (stride == 1) {
    for (var i = 0; i < a.length; i++) {
      final d = a[i] - b[i];
      sumSq += d * d;
      count++;
    }
  } else {
    for (var i = 0; i < a.length; i += 4) {
      final dr = a[i] - b[i];
      final dg = a[i + 1] - b[i + 1];
      final db = a[i + 2] - b[i + 2];
      sumSq += dr * dr + dg * dg + db * db;
      count += 3;
    }
  }
  if (count == 0) return 0;
  return sumSq / count;
}

/// PSNR in dB for two equal-size buffers.
///
/// Returns `double.infinity` when the inputs are identical (MSE = 0).
/// The lab clamps that to 100 dB for display purposes.
double computePsnr(
  Uint8List a,
  Uint8List b, {
  required int stride,
  double maxValue = 255,
}) {
  final mse = computeMse(a, b, stride: stride);
  if (mse == 0) return double.infinity;
  return 10 * math.log(maxValue * maxValue / mse) / math.ln10;
}
