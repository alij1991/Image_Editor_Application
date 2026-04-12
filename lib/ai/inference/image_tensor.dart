import 'dart:typed_data';

/// Converts an RGBA pixel buffer into a `[1, 3, H, W]` (CHW) Float32
/// tensor suitable for feeding into a PyTorch-style neural network.
///
/// This is the preprocessing path for MODNet, RMBG, U2-Net, and most
/// other image-to-mask models: bilinear resize → drop alpha → reorder
/// HWC→CHW → normalize. Kept in pure Dart (no `dart:ui`) so it can run
/// inside an isolate and be unit-tested without a Flutter binding.
///
/// Per-channel normalization follows the `(x/255 - mean) / std` formula.
/// Pass `mean=[0.5, 0.5, 0.5]`, `std=[0.5, 0.5, 0.5]` for MODNet (maps
/// to `[-1, 1]`), or omit both for a plain `[0, 1]` scale (RMBG).
class ImageTensor {
  const ImageTensor._({required this.data, required this.shape});

  /// Flat CHW buffer. Length is `3 * shape[2] * shape[3]`.
  final Float32List data;

  /// `[1, 3, H, W]`. Leading batch dimension is always 1.
  final List<int> shape;

  /// Output tensor height (convenience).
  int get height => shape[2];

  /// Output tensor width (convenience).
  int get width => shape[3];

  /// Build a normalized tensor from a source RGBA buffer.
  ///
  /// - [rgba] is a `srcWidth × srcHeight` RGBA8 buffer (4 bytes/pixel).
  /// - [dstWidth] / [dstHeight] is the tensor spatial resolution.
  /// - [mean] / [std] are per-channel normalization params. Defaults
  ///   (`mean=0, std=1`) produce a `[0, 1]` tensor.
  ///
  /// Throws [ArgumentError] on invalid dimensions or RGBA length.
  factory ImageTensor.fromRgba({
    required Uint8List rgba,
    required int srcWidth,
    required int srcHeight,
    required int dstWidth,
    required int dstHeight,
    List<double>? mean,
    List<double>? std,
  }) {
    if (srcWidth <= 0 || srcHeight <= 0) {
      throw ArgumentError('srcWidth and srcHeight must be > 0');
    }
    if (dstWidth <= 0 || dstHeight <= 0) {
      throw ArgumentError('dstWidth and dstHeight must be > 0');
    }
    final expected = srcWidth * srcHeight * 4;
    if (rgba.length != expected) {
      throw ArgumentError(
        'rgba length ${rgba.length} does not match $srcWidth×$srcHeight×4 ($expected)',
      );
    }
    if (mean != null && mean.length != 3) {
      throw ArgumentError('mean must have length 3');
    }
    if (std != null && std.length != 3) {
      throw ArgumentError('std must have length 3');
    }

    final mR = mean?[0] ?? 0.0;
    final mG = mean?[1] ?? 0.0;
    final mB = mean?[2] ?? 0.0;
    final sR = std?[0] ?? 1.0;
    final sG = std?[1] ?? 1.0;
    final sB = std?[2] ?? 1.0;

    final hw = dstWidth * dstHeight;
    final out = Float32List(3 * hw);

    // Pre-compute the fractional step so we don't re-divide per pixel.
    // We use (src - 1) / (dst - 1) so the first and last sample land
    // exactly on the source edges — this keeps the resize artifact-
    // free when dst == src (identity passthrough).
    final yDen = dstHeight > 1 ? (dstHeight - 1) : 1;
    final xDen = dstWidth > 1 ? (dstWidth - 1) : 1;
    final yScale = (srcHeight - 1) / yDen;
    final xScale = (srcWidth - 1) / xDen;

    for (int y = 0; y < dstHeight; y++) {
      final sy = y * yScale;
      final y0 = sy.floor().clamp(0, srcHeight - 1);
      final y1 = (y0 + 1).clamp(0, srcHeight - 1);
      final wy = sy - y0;
      for (int x = 0; x < dstWidth; x++) {
        final sx = x * xScale;
        final x0 = sx.floor().clamp(0, srcWidth - 1);
        final x1 = (x0 + 1).clamp(0, srcWidth - 1);
        final wx = sx - x0;

        final i00 = (y0 * srcWidth + x0) * 4;
        final i01 = (y0 * srcWidth + x1) * 4;
        final i10 = (y1 * srcWidth + x0) * 4;
        final i11 = (y1 * srcWidth + x1) * 4;

        // Bilinear interpolate each channel in uint8 space, then /255.
        final r =
            ((rgba[i00] * (1 - wx) + rgba[i01] * wx) * (1 - wy) +
                    (rgba[i10] * (1 - wx) + rgba[i11] * wx) * wy) /
                255.0;
        final g =
            ((rgba[i00 + 1] * (1 - wx) + rgba[i01 + 1] * wx) * (1 - wy) +
                    (rgba[i10 + 1] * (1 - wx) + rgba[i11 + 1] * wx) * wy) /
                255.0;
        final b =
            ((rgba[i00 + 2] * (1 - wx) + rgba[i01 + 2] * wx) * (1 - wy) +
                    (rgba[i10 + 2] * (1 - wx) + rgba[i11 + 2] * wx) * wy) /
                255.0;

        final pIdx = y * dstWidth + x;
        // CHW layout: channel plane index = c * (H*W).
        out[pIdx] = (r - mR) / sR;
        out[hw + pIdx] = (g - mG) / sG;
        out[hw * 2 + pIdx] = (b - mB) / sB;
      }
    }
    return ImageTensor._(
      data: out,
      shape: [1, 3, dstHeight, dstWidth],
    );
  }

  /// Reshape the flat buffer into `[1][3][H][W]` nested lists — the
  /// form `flutter_litert`'s `Interpreter.runForMultipleInputs`
  /// expects for a typed input tensor. This is a view over [data], so
  /// mutating either side mutates both.
  List<List<List<List<double>>>> asNested() {
    final h = height;
    final w = width;
    final hw = h * w;
    return [
      [
        for (int c = 0; c < 3; c++)
          [
            for (int y = 0; y < h; y++)
              [
                for (int x = 0; x < w; x++) data[c * hw + y * w + x],
              ],
          ],
      ],
    ];
  }
}
