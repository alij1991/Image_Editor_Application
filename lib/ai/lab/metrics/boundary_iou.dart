/// XVI.95a — Boundary IoU (Cheng et al., CVPR 2021).
///
/// Plain mask IoU under-penalises boundary errors on large objects:
/// interior pixels grow quadratically with object size while boundary
/// pixels grow linearly. For our hair-detail / sky-horizon test cases
/// that's the exact information we care about, so Boundary IoU is the
/// discriminating metric for matting / matting-like ops.
///
/// Algorithm:
///   1. For each mask, compute the boundary band of width `d`
///      (= mask MINUS its `d`-pixel erosion). `d` defaults to
///      `max(2, round(min(W, H) * 0.02))` per the paper.
///   2. Standard IoU of the two boundary bands.
///
/// The single-pixel erosion is iterated `d` times — O(d × W × H),
/// fast enough for the lab's typical 2K test images.
library;

import 'dart:math' as math;
import 'dart:typed_data';

import 'mask_iou.dart' show computeMaskIou;

/// Default boundary-band width as a fraction of the smaller image
/// dimension. 2 % matches the recommended setting in Cheng et al.
const double _defaultDilationRatio = 0.02;

/// Recommended boundary-band width for an image of size [w] × [h].
int boundaryDilationFor(int w, int h) {
  final shortEdge = w < h ? w : h;
  return math.max(2, (shortEdge * _defaultDilationRatio).round());
}

/// Erode a binary mask by 1 pixel (4-connectivity).
///
/// A foreground pixel survives only if all four N/S/W/E neighbours
/// are also foreground. Pixels outside the image are treated as
/// background, so the border erodes first — this matches Cheng et
/// al.'s definition where the boundary band always includes the
/// frame edges.
Uint8List erodeMaskOnce(
  Uint8List mask, {
  required int width,
  required int height,
}) {
  if (mask.length != width * height) {
    throw ArgumentError(
      'mask buffer size ${mask.length} != $width * $height',
    );
  }
  final out = Uint8List(mask.length);
  for (var y = 0; y < height; y++) {
    for (var x = 0; x < width; x++) {
      final i = y * width + x;
      if (mask[i] == 0) {
        out[i] = 0;
        continue;
      }
      if (x == 0 || y == 0 || x == width - 1 || y == height - 1) {
        out[i] = 0;
        continue;
      }
      final n = mask[(y - 1) * width + x];
      final s = mask[(y + 1) * width + x];
      final w = mask[y * width + (x - 1)];
      final e = mask[y * width + (x + 1)];
      out[i] = (n != 0 && s != 0 && w != 0 && e != 0) ? 1 : 0;
    }
  }
  return out;
}

/// Erode a binary mask by [radius] pixels via iterated 1-pixel
/// erosion. Returns a fresh buffer.
Uint8List erodeMaskBy(
  Uint8List mask, {
  required int width,
  required int height,
  required int radius,
}) {
  var current = mask;
  for (var i = 0; i < radius; i++) {
    current = erodeMaskOnce(current, width: width, height: height);
  }
  return current;
}

/// Boundary band of a binary mask: `mask AND NOT erode(mask, d)`.
Uint8List boundaryBand(
  Uint8List mask, {
  required int width,
  required int height,
  required int radius,
}) {
  final eroded = erodeMaskBy(
    mask,
    width: width,
    height: height,
    radius: radius,
  );
  final out = Uint8List(mask.length);
  for (var i = 0; i < mask.length; i++) {
    out[i] = (mask[i] != 0 && eroded[i] == 0) ? 1 : 0;
  }
  return out;
}

/// Boundary IoU between two binary masks. [dilation] defaults to
/// 2 % of the smaller dimension per Cheng et al.
double computeBoundaryIou(
  Uint8List predicted,
  Uint8List groundTruth, {
  required int width,
  required int height,
  int? dilation,
}) {
  if (predicted.length != groundTruth.length) {
    throw ArgumentError(
      'boundary IoU buffers must match: pred=${predicted.length} '
      'gt=${groundTruth.length}',
    );
  }
  final d = dilation ?? boundaryDilationFor(width, height);
  final predBand = boundaryBand(
    predicted,
    width: width,
    height: height,
    radius: d,
  );
  final gtBand = boundaryBand(
    groundTruth,
    width: width,
    height: height,
    radius: d,
  );
  return computeMaskIou(predBand, gtBand);
}
