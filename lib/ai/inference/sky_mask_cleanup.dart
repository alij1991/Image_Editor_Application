/// XVI.106 — connectivity cleanup for the sky-replace mask.
///
/// The sky mask is the union of a colour/top-bias heuristic, a
/// SegFormer sky head, and a DeepLab object filter. On a clear-blue-
/// sky day the union over-claims: bright tulip rows / hazy foreground
/// near the horizon score as "sky", so the replacement (especially a
/// DARK night preset) paints blobs onto flowers below the horizon.
/// The device log on the tulip-bench photo showed mask coverage
/// 0.55 of the frame when the real sky is ~0.35.
///
/// The XVI.100 colour gate ([dropNonSkyPixels]) only removes pixels
/// whose RGB clearly isn't sky-coloured — but warm tulips (red /
/// yellow) pass its warmness branch, so they survive. The remaining
/// bleed has a different structural signature: it is **disconnected
/// from the real sky**. The real sky is one big region that reaches
/// the TOP edge of the frame; the bleed blobs sit in the middle,
/// separated from the sky by the (non-sky) mountains / horizon.
///
/// This helper enforces the classic "sky connects to the top of the
/// frame" rule: label the mask's connected components, keep only
/// those that touch row 0, and zero the rest. It is robust to the
/// split-sky-around-a-head case (both halves still touch the top) and
/// degrades safely (if NOTHING touches the top — an unusual framing —
/// it leaves the mask untouched rather than nuking everything).
library;

import 'dart:typed_data';

/// Result of [keepSkyComponentsTouchingTop]: the cleaned mask plus
/// counts for logging.
class SkyConnectivityResult {
  const SkyConnectivityResult({
    required this.droppedPixels,
    required this.keptTouchedTop,
  });

  /// Number of mask pixels zeroed because they belonged to a
  /// component that did not reach the top edge.
  final int droppedPixels;

  /// True if at least one component touched the top (the rule was
  /// applied). False means the safe no-op fallback fired.
  final bool keptTouchedTop;
}

/// Zero every soft-mask pixel that belongs to a connected component
/// not touching the top edge of the frame. Operates in place on
/// [mask] (a `Float32List` of length `width * height`, values in
/// `[0, 1]`).
///
/// [threshold] binarises the soft mask before labelling (default
/// 0.5). [minTopRun] guards against a single stray top-row pixel
/// anchoring a bleed component: a component must touch the top edge
/// in at least this many cells to count as "connected to the top".
///
/// Returns a [SkyConnectivityResult]. If no component touches the
/// top edge at all, the mask is left unchanged and `keptTouchedTop`
/// is false.
SkyConnectivityResult keepSkyComponentsTouchingTop(
  Float32List mask, {
  required int width,
  required int height,
  double threshold = 0.5,
  int minTopRun = 1,
}) {
  if (mask.length != width * height) {
    throw ArgumentError(
      'mask length ${mask.length} != $width * $height',
    );
  }
  if (width <= 0 || height <= 0) {
    return const SkyConnectivityResult(droppedPixels: 0, keptTouchedTop: false);
  }

  final n = width * height;
  // labels: 0 = background (below threshold), >0 = component id.
  final labels = Int32List(n);
  // Per-component top-edge touch count.
  final topTouch = <int, int>{};
  var nextLabel = 0;

  // Iterative flood fill (BFS) using a reusable queue buffer.
  final queue = Int32List(n);

  for (var start = 0; start < n; start++) {
    if (mask[start] < threshold || labels[start] != 0) continue;
    nextLabel++;
    var head = 0;
    var tail = 0;
    queue[tail++] = start;
    labels[start] = nextLabel;
    var topCount = 0;
    while (head < tail) {
      final idx = queue[head++];
      final y = idx ~/ width;
      final x = idx - y * width;
      if (y == 0) topCount++;
      // 4-connectivity neighbours.
      if (x > 0) {
        final nb = idx - 1;
        if (mask[nb] >= threshold && labels[nb] == 0) {
          labels[nb] = nextLabel;
          queue[tail++] = nb;
        }
      }
      if (x < width - 1) {
        final nb = idx + 1;
        if (mask[nb] >= threshold && labels[nb] == 0) {
          labels[nb] = nextLabel;
          queue[tail++] = nb;
        }
      }
      if (y > 0) {
        final nb = idx - width;
        if (mask[nb] >= threshold && labels[nb] == 0) {
          labels[nb] = nextLabel;
          queue[tail++] = nb;
        }
      }
      if (y < height - 1) {
        final nb = idx + width;
        if (mask[nb] >= threshold && labels[nb] == 0) {
          labels[nb] = nextLabel;
          queue[tail++] = nb;
        }
      }
    }
    topTouch[nextLabel] = topCount;
  }

  // Which components touch the top?
  final keep = <int>{};
  for (final entry in topTouch.entries) {
    if (entry.value >= minTopRun) keep.add(entry.key);
  }

  // Safe fallback: if nothing reaches the top, don't nuke the mask.
  if (keep.isEmpty) {
    return const SkyConnectivityResult(
      droppedPixels: 0,
      keptTouchedTop: false,
    );
  }

  var dropped = 0;
  for (var i = 0; i < n; i++) {
    final l = labels[i];
    if (l != 0 && !keep.contains(l)) {
      if (mask[i] > 0) dropped++;
      mask[i] = 0;
    }
  }
  return SkyConnectivityResult(droppedPixels: dropped, keptTouchedTop: true);
}
