import 'dart:typed_data';

/// Upsample a low-resolution alpha matte back to source-image
/// resolution using bilinear interpolation, then splat it into an RGBA
/// buffer (keeping RGB, replacing alpha).
///
/// This is the postprocessing counterpart to [ImageTensor] — MODNet,
/// RMBG, and U²-Net all emit a `[1, 1, H, W]` float mask in `[0, 1]`
/// which we need to project back onto the (possibly much larger)
/// source image.
///
/// Kept in pure Dart with no `dart:ui` dependency so it can run inside
/// an isolate worker and be unit-tested. Callers are responsible for
/// feeding a correctly-sized `sourceRgba` — throws [ArgumentError] on
/// length mismatch.
Uint8List blendMaskIntoRgba({
  required Float32List mask,
  required int maskWidth,
  required int maskHeight,
  required Uint8List sourceRgba,
  required int srcWidth,
  required int srcHeight,
  double threshold = 0.0,
}) {
  if (maskWidth <= 0 || maskHeight <= 0) {
    throw ArgumentError('mask dimensions must be > 0');
  }
  if (srcWidth <= 0 || srcHeight <= 0) {
    throw ArgumentError('src dimensions must be > 0');
  }
  if (mask.length != maskWidth * maskHeight) {
    throw ArgumentError(
      'mask length ${mask.length} does not match $maskWidth×$maskHeight',
    );
  }
  final expectedRgba = srcWidth * srcHeight * 4;
  if (sourceRgba.length != expectedRgba) {
    throw ArgumentError(
      'sourceRgba length ${sourceRgba.length} does not match $srcWidth×$srcHeight×4 ($expectedRgba)',
    );
  }

  // Copy the source so callers retain ownership of the input buffer.
  final out = Uint8List.fromList(sourceRgba);

  final yDen = srcHeight > 1 ? (srcHeight - 1) : 1;
  final xDen = srcWidth > 1 ? (srcWidth - 1) : 1;
  final yScale = (maskHeight - 1) / yDen;
  final xScale = (maskWidth - 1) / xDen;

  for (int y = 0; y < srcHeight; y++) {
    final sy = y * yScale;
    final y0 = sy.floor().clamp(0, maskHeight - 1);
    final y1 = (y0 + 1).clamp(0, maskHeight - 1);
    final wy = sy - y0;
    for (int x = 0; x < srcWidth; x++) {
      final sx = x * xScale;
      final x0 = sx.floor().clamp(0, maskWidth - 1);
      final x1 = (x0 + 1).clamp(0, maskWidth - 1);
      final wx = sx - x0;

      final m00 = mask[y0 * maskWidth + x0];
      final m01 = mask[y0 * maskWidth + x1];
      final m10 = mask[y1 * maskWidth + x0];
      final m11 = mask[y1 * maskWidth + x1];
      final a = m00 * (1 - wx) + m01 * wx;
      final b = m10 * (1 - wx) + m11 * wx;
      double v = a * (1 - wy) + b * wy;
      // Optional hard threshold — some models benefit from a
      // binarization step. When threshold == 0 we keep the soft matte.
      if (threshold > 0) {
        v = v < threshold ? 0 : 1;
      }
      if (v < 0) v = 0;
      if (v > 1) v = 1;
      out[(y * srcWidth + x) * 4 + 3] = (v * 255).round();
    }
  }
  return out;
}
