import 'dart:typed_data';

/// Pure-Dart per-pixel RGB adjustments used by Phase 9e beauty
/// services. Each helper returns a fresh RGBA8 buffer and never
/// mutates the caller's input. Alpha is always preserved — these
/// operations are meant to be composited onto the original via a
/// landmark mask later, so touching alpha would break the blend.
class RgbOps {
  const RgbOps._();

  /// Multiply every RGB channel by [factor] and clamp to `[0, 255]`.
  ///
  /// - `factor < 1.0` darkens; `factor > 1.0` brightens.
  /// - Alpha is copied through.
  ///
  /// Kept simple on purpose — the mask composite step controls
  /// *where* the brightness lands, so we don't need fancy highlight
  /// rolloff inside the kernel.
  static Uint8List brightenRgb({
    required Uint8List source,
    required int width,
    required int height,
    required double factor,
  }) {
    if (width <= 0 || height <= 0) {
      throw ArgumentError('width/height must be > 0');
    }
    if (source.length != width * height * 4) {
      throw ArgumentError(
        'source length ${source.length} != ${width * height * 4}',
      );
    }
    if (factor < 0) {
      throw ArgumentError('factor must be >= 0');
    }

    final out = Uint8List(source.length);
    for (int i = 0; i < source.length; i += 4) {
      final r = source[i] * factor;
      final g = source[i + 1] * factor;
      final b = source[i + 2] * factor;
      out[i] = r < 0 ? 0 : (r > 255 ? 255 : r.round());
      out[i + 1] = g < 0 ? 0 : (g > 255 ? 255 : g.round());
      out[i + 2] = b < 0 ? 0 : (b > 255 ? 255 : b.round());
      out[i + 3] = source[i + 3];
    }
    return out;
  }

  /// Desaturate + brighten — the "whitening" kernel for teeth.
  ///
  /// For every pixel, compute the Rec. 709 luminance `L` and push
  /// each channel toward `L` by [desaturate] (so `0` = no change,
  /// `1` = fully greyscale), then multiply by [brightness] and
  /// clamp. The combined effect is a gentle yellow-cast reducer +
  /// highlight bump, which is what the common teeth-whiten recipe
  /// does in LAB space without the overhead.
  ///
  /// Alpha is copied through. This op is applied uniformly inside a
  /// mouth-shape mask — the mask, not the kernel, is responsible
  /// for keeping it off the lips and skin.
  static Uint8List whitenRgb({
    required Uint8List source,
    required int width,
    required int height,
    required double desaturate,
    required double brightness,
  }) {
    if (width <= 0 || height <= 0) {
      throw ArgumentError('width/height must be > 0');
    }
    if (source.length != width * height * 4) {
      throw ArgumentError(
        'source length ${source.length} != ${width * height * 4}',
      );
    }
    if (desaturate < 0 || desaturate > 1) {
      throw ArgumentError('desaturate must be in [0, 1]');
    }
    if (brightness < 0) {
      throw ArgumentError('brightness must be >= 0');
    }

    final keep = 1 - desaturate;
    final out = Uint8List(source.length);
    for (int i = 0; i < source.length; i += 4) {
      final r = source[i].toDouble();
      final g = source[i + 1].toDouble();
      final b = source[i + 2].toDouble();
      // Rec. 709 luminance (same weights as the ITU-R standard).
      final lum = 0.2126 * r + 0.7152 * g + 0.0722 * b;
      final nr = (lum + (r - lum) * keep) * brightness;
      final ng = (lum + (g - lum) * keep) * brightness;
      final nb = (lum + (b - lum) * keep) * brightness;
      out[i] = nr < 0 ? 0 : (nr > 255 ? 255 : nr.round());
      out[i + 1] = ng < 0 ? 0 : (ng > 255 ? 255 : ng.round());
      out[i + 2] = nb < 0 ? 0 : (nb > 255 ? 255 : nb.round());
      out[i + 3] = source[i + 3];
    }
    return out;
  }
}
