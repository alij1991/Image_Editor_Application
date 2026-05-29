/// XVI.107 — connected-component splitting for inpaint masks.
///
/// "Remove Object" paints an RGBA mask (R ≥ 128 = paint). The
/// inpaint service used to take ONE bounding box over every painted
/// pixel. When the user paints two well-separated objects (or a
/// sparse, spread-out selection) that single bbox can span almost
/// the whole frame — and LaMa's input is hard-fixed at 512², so the
/// tile gets downscaled 5–6× and the fill ghosts (device log:
/// `tile bbox w=2953 h=2952 maskRatio=0.168`).
///
/// Splitting the mask into connected components lets the service run
/// LaMa on a tight 512 tile PER region, so each downscales far less.
/// A single connected blob (e.g. one object) yields one component,
/// so the common case is unchanged.
library;

import 'dart:typed_data';

/// Labelled connected components of a painted mask.
class MaskComponents {
  MaskComponents({
    required this.labels,
    required this.width,
    required this.height,
    required this.sizes,
  });

  /// Per-pixel component id. 0 = background (unpainted). >0 = a
  /// component id (1-based).
  final Int32List labels;
  final int width;
  final int height;

  /// component id → painted-pixel count.
  final Map<int, int> sizes;

  /// Number of components found.
  int get count => sizes.length;

  /// Component ids ordered largest-first, dropping any below
  /// [minPixels] (noise specks). Returns an empty list when nothing
  /// is painted.
  List<int> labelsBySizeDesc({int minPixels = 0}) {
    final ids = sizes.keys
        .where((id) => sizes[id]! >= minPixels)
        .toList(growable: false);
    ids.sort((a, b) => sizes[b]!.compareTo(sizes[a]!));
    return ids;
  }
}

/// Label 4-connected components of the painted region (R ≥
/// [threshold]) in [maskRgba] (RGBA, [width] × [height]).
MaskComponents labelMaskComponents(
  Uint8List maskRgba, {
  required int width,
  required int height,
  int threshold = 128,
}) {
  if (maskRgba.length != width * height * 4) {
    throw ArgumentError(
      'maskRgba length ${maskRgba.length} != $width * $height * 4',
    );
  }
  final n = width * height;
  final labels = Int32List(n);
  final sizes = <int, int>{};
  if (n == 0) {
    return MaskComponents(
      labels: labels,
      width: width,
      height: height,
      sizes: sizes,
    );
  }
  final queue = Int32List(n);
  var nextLabel = 0;

  bool painted(int idx) => maskRgba[idx * 4] >= threshold;

  for (var start = 0; start < n; start++) {
    if (!painted(start) || labels[start] != 0) continue;
    nextLabel++;
    var head = 0;
    var tail = 0;
    queue[tail++] = start;
    labels[start] = nextLabel;
    var size = 0;
    while (head < tail) {
      final idx = queue[head++];
      size++;
      final y = idx ~/ width;
      final x = idx - y * width;
      if (x > 0) {
        final nb = idx - 1;
        if (painted(nb) && labels[nb] == 0) {
          labels[nb] = nextLabel;
          queue[tail++] = nb;
        }
      }
      if (x < width - 1) {
        final nb = idx + 1;
        if (painted(nb) && labels[nb] == 0) {
          labels[nb] = nextLabel;
          queue[tail++] = nb;
        }
      }
      if (y > 0) {
        final nb = idx - width;
        if (painted(nb) && labels[nb] == 0) {
          labels[nb] = nextLabel;
          queue[tail++] = nb;
        }
      }
      if (y < height - 1) {
        final nb = idx + width;
        if (painted(nb) && labels[nb] == 0) {
          labels[nb] = nextLabel;
          queue[tail++] = nb;
        }
      }
    }
    sizes[nextLabel] = size;
  }

  return MaskComponents(
    labels: labels,
    width: width,
    height: height,
    sizes: sizes,
  );
}

/// Build a mask RGBA buffer containing ONLY the pixels of component
/// [label] — every other pixel is zeroed. The kept pixels retain
/// their original [sourceMaskRgba] values (so soft/anti-aliased mask
/// edges survive into the composite).
Uint8List extractComponentMask(
  MaskComponents comps,
  Uint8List sourceMaskRgba,
  int label,
) {
  final n = comps.width * comps.height;
  if (sourceMaskRgba.length != n * 4) {
    throw ArgumentError(
      'sourceMaskRgba length ${sourceMaskRgba.length} != $n * 4',
    );
  }
  final out = Uint8List(n * 4);
  for (var i = 0; i < n; i++) {
    if (comps.labels[i] == label) {
      final p = i * 4;
      out[p] = sourceMaskRgba[p];
      out[p + 1] = sourceMaskRgba[p + 1];
      out[p + 2] = sourceMaskRgba[p + 2];
      out[p + 3] = sourceMaskRgba[p + 3];
    }
  }
  return out;
}
