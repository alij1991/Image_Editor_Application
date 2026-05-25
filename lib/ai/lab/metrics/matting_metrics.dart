/// XVI.95a — Matting-specific metrics (SAD, Gradient error).
///
/// Standard alpha-matting evaluation set (alphamatting.com / Rhemann
/// et al.):
///
/// - **SAD**  Sum of Absolute Differences between predicted and
///   ground-truth alpha, computed only within the trimap's unknown
///   region. Lower is better; reported in units of `alpha` (0..1).
/// - **Grad** Sum of Absolute Differences of horizontal+vertical
///   gradients (Sobel) of predicted vs ground-truth alpha, again
///   within the unknown region. Captures whether the matte's
///   transition band is sharp at the right places.
///
/// The trimap encodes three states per pixel:
///   - foreground (255) — required to be alpha=1
///   - background (0)   — required to be alpha=0
///   - unknown   (128) — soft transition; SAD/Grad accumulate here
///
/// If no trimap is supplied the metric falls back to summing across
/// the whole image — coarse but useful when the only ground truth
/// available is a binary mask.
library;

import 'dart:math' as math;
import 'dart:typed_data';

/// Marker bytes for the trimap encoding.
const int kTrimapBg = 0;
const int kTrimapUnknown = 128;
const int kTrimapFg = 255;

/// Build a mask of "unknown region" cells from a trimap byte buffer.
///
/// Cells within `±tolerance` of [kTrimapUnknown] count as unknown.
Uint8List unknownRegionFromTrimap(Uint8List trimap, {int tolerance = 32}) {
  final out = Uint8List(trimap.length);
  final lo = kTrimapUnknown - tolerance;
  final hi = kTrimapUnknown + tolerance;
  for (var i = 0; i < trimap.length; i++) {
    out[i] = (trimap[i] >= lo && trimap[i] <= hi) ? 1 : 0;
  }
  return out;
}

/// SAD between two alpha buffers in `[0, 1]`, restricted to the
/// `unknownRegion` mask if supplied. Normalised by the number of
/// pixels actually summed so the result is comparable across images.
double computeSad(
  Float32List predicted,
  Float32List groundTruth, {
  Uint8List? unknownRegion,
}) {
  if (predicted.length != groundTruth.length) {
    throw ArgumentError(
      'SAD buffers must match: pred=${predicted.length} '
      'gt=${groundTruth.length}',
    );
  }
  if (unknownRegion != null && unknownRegion.length != predicted.length) {
    throw ArgumentError(
      'unknown region size ${unknownRegion.length} != ${predicted.length}',
    );
  }
  if (predicted.isEmpty) return 0;
  double sum = 0;
  int count = 0;
  for (var i = 0; i < predicted.length; i++) {
    if (unknownRegion != null && unknownRegion[i] == 0) continue;
    sum += (predicted[i] - groundTruth[i]).abs();
    count++;
  }
  return count == 0 ? 0 : sum / count;
}

/// Gradient error: SAD of Sobel gradients of [predicted] vs
/// [groundTruth] alpha within the unknown region.
///
/// Uses the 3×3 Sobel kernels:
/// ```
///   Gx = [[-1,0,1],[-2,0,2],[-1,0,1]]
///   Gy = [[-1,-2,-1],[0,0,0],[1,2,1]]
/// ```
/// Magnitude = `sqrt(Gx² + Gy²)`. The metric is the mean absolute
/// difference of magnitudes inside the unknown region.
double computeGradientError(
  Float32List predicted,
  Float32List groundTruth, {
  required int width,
  required int height,
  Uint8List? unknownRegion,
}) {
  if (predicted.length != width * height ||
      groundTruth.length != width * height) {
    throw ArgumentError(
      'gradient error: buffer size != width*height '
      '(${predicted.length}, ${groundTruth.length}, $width*$height)',
    );
  }
  if (width < 3 || height < 3) return 0;
  double sum = 0;
  int count = 0;
  for (var y = 1; y < height - 1; y++) {
    for (var x = 1; x < width - 1; x++) {
      final i = y * width + x;
      if (unknownRegion != null && unknownRegion[i] == 0) continue;
      sum += (_sobelMag(predicted, x, y, width) -
              _sobelMag(groundTruth, x, y, width))
          .abs();
      count++;
    }
  }
  return count == 0 ? 0 : sum / count;
}

double _sobelMag(Float32List buf, int x, int y, int width) {
  final tl = buf[(y - 1) * width + (x - 1)];
  final tc = buf[(y - 1) * width + x];
  final tr = buf[(y - 1) * width + (x + 1)];
  final ml = buf[y * width + (x - 1)];
  final mr = buf[y * width + (x + 1)];
  final bl = buf[(y + 1) * width + (x - 1)];
  final bc = buf[(y + 1) * width + x];
  final br = buf[(y + 1) * width + (x + 1)];
  final gx = (-tl + tr) + (-2 * ml + 2 * mr) + (-bl + br);
  final gy = (-tl - 2 * tc - tr) + (bl + 2 * bc + br);
  return math.sqrt(gx * gx + gy * gy);
}
