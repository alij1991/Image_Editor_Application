/// XVI.95a — Binary mask Intersection-over-Union.
///
/// Used as the segmentation primary metric for every BG removal /
/// MobileSAM / sky-replace ground-truth comparison. The threshold
/// from the strategy doc is `IoU >= 0.85` for BG removal and `>= 0.80`
/// per MobileSAM tap. The companion Boundary IoU (see
/// [boundary_iou.dart]) is the more discriminating metric for large
/// objects with detailed edges (hair, foliage) per Cheng et al. CVPR
/// 2021; ship both side-by-side in the lab UI.
///
/// Masks may be `Float32List` (soft alpha, values in `[0, 1]`) or
/// `Uint8List` (alpha or single-channel binary, `0..255`). The
/// helpers binarise at a configurable threshold (default `0.5` for
/// floats, `128` for bytes).
library;

import 'dart:typed_data';

/// Convert a soft mask in `[0, 1]` to a binary `Uint8List` (0 or 1).
Uint8List binariseFloatMask(
  Float32List mask, {
  double threshold = 0.5,
}) {
  final out = Uint8List(mask.length);
  for (var i = 0; i < mask.length; i++) {
    out[i] = mask[i] >= threshold ? 1 : 0;
  }
  return out;
}

/// Convert a 0..255 byte mask (alpha or grayscale) to a binary
/// `Uint8List` (0 or 1).
///
/// If [stride] is 4 the buffer is RGBA and the alpha channel is used.
/// If [stride] is 1 the buffer is single-channel.
Uint8List binariseByteMask(
  Uint8List mask, {
  int stride = 1,
  int threshold = 128,
}) {
  assert(stride == 1 || stride == 4);
  if (stride == 1) {
    final out = Uint8List(mask.length);
    for (var i = 0; i < mask.length; i++) {
      out[i] = mask[i] >= threshold ? 1 : 0;
    }
    return out;
  }
  final out = Uint8List(mask.length ~/ 4);
  for (var i = 0, j = 0; i < mask.length; i += 4, j++) {
    out[j] = mask[i + 3] >= threshold ? 1 : 0;
  }
  return out;
}

/// Mask IoU between two binary masks (`0` or `1` per cell).
///
/// Returns `1.0` when both masks are empty (vacuous agreement) — the
/// caller is responsible for guarding against that case if it
/// matters for grading (e.g. lab refuses to grade "MobileSAM produced
/// no mask" as a pass).
double computeMaskIou(Uint8List predicted, Uint8List groundTruth) {
  if (predicted.length != groundTruth.length) {
    throw ArgumentError(
      'mask IoU buffers must match: pred=${predicted.length} '
      'gt=${groundTruth.length}',
    );
  }
  if (predicted.isEmpty) return 1;
  int intersection = 0;
  int union = 0;
  for (var i = 0; i < predicted.length; i++) {
    final p = predicted[i] != 0;
    final g = groundTruth[i] != 0;
    if (p && g) intersection++;
    if (p || g) union++;
  }
  if (union == 0) return 1; // both empty
  return intersection / union;
}

/// Coverage of a binary mask: fraction of cells set to 1.
///
/// Used by the sky-replace gate to verify the mask covers the
/// labeled-sky region within `±5%`. Range `[0, 1]`.
double computeMaskCoverage(Uint8List mask) {
  if (mask.isEmpty) return 0;
  int on = 0;
  for (var i = 0; i < mask.length; i++) {
    if (mask[i] != 0) on++;
  }
  return on / mask.length;
}

/// Fraction of pixels OUTSIDE [groundTruth] that the predicted mask
/// marks as positive. Used by the sky-replace gate to catch the
/// XVI.93a regression where the mask bled into flowers and bench.
///
/// `pred & !gt` over total pixels — values closer to 0 are better.
double computeFalsePositiveRate(
  Uint8List predicted,
  Uint8List groundTruth,
) {
  if (predicted.length != groundTruth.length) {
    throw ArgumentError(
      'mask buffers must match: pred=${predicted.length} '
      'gt=${groundTruth.length}',
    );
  }
  if (predicted.isEmpty) return 0;
  int fp = 0;
  for (var i = 0; i < predicted.length; i++) {
    if (predicted[i] != 0 && groundTruth[i] == 0) fp++;
  }
  return fp / predicted.length;
}
