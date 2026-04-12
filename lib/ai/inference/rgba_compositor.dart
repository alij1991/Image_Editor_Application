import 'dart:typed_data';

/// Alpha-blend an [overlay] RGBA8 buffer on top of a [base] RGBA8
/// buffer using a single-channel [mask] as the blend factor.
///
/// For each pixel:
///   `out = base * (1 - mask[i]) + overlay * mask[i]`
/// — so `mask=0` keeps `base` unchanged, `mask=1` fully replaces
/// with `overlay`, and smooth values in between interpolate.
///
/// The mask is in **source-image resolution** (same as `base` and
/// `overlay`) and stored as a flat `width*height` `Float32List` in
/// `[0, 1]`. Used by Phase 9d's portrait-smoothing service to fade
/// a blurred copy of the image into the original only where the
/// face mask says "here".
///
/// The returned buffer is a fresh copy; neither input is mutated.
Uint8List compositeOverlayRgba({
  required Uint8List base,
  required Uint8List overlay,
  required Float32List mask,
  required int width,
  required int height,
}) {
  if (width <= 0 || height <= 0) {
    throw ArgumentError('width/height must be > 0');
  }
  final pixelCount = width * height;
  if (base.length != pixelCount * 4) {
    throw ArgumentError(
      'base length ${base.length} != ${pixelCount * 4}',
    );
  }
  if (overlay.length != pixelCount * 4) {
    throw ArgumentError(
      'overlay length ${overlay.length} != ${pixelCount * 4}',
    );
  }
  if (mask.length != pixelCount) {
    throw ArgumentError(
      'mask length ${mask.length} != $pixelCount',
    );
  }

  final out = Uint8List(base.length);
  for (int i = 0; i < pixelCount; i++) {
    double a = mask[i];
    if (a < 0) a = 0;
    if (a > 1) a = 1;
    final inv = 1 - a;
    final o = i * 4;
    out[o] = (base[o] * inv + overlay[o] * a).round();
    out[o + 1] = (base[o + 1] * inv + overlay[o + 1] * a).round();
    out[o + 2] = (base[o + 2] * inv + overlay[o + 2] * a).round();
    // Alpha channel: keep the base's alpha. The mask controls
    // WHERE the blur applies, not whether pixels are visible.
    out[o + 3] = base[o + 3];
  }
  return out;
}
