import 'dart:typed_data';

import 'box_blur.dart';

/// Fast edge-preserving blur — a bilateral-filter approximation that
/// keeps features (eyes, brow lines, lip edges) sharp while smoothing
/// low-contrast texture (pores, minor colour variation on skin).
///
/// A true bilateral filter computes a per-pixel weighted average of
/// its neighbours with the weight falling off by both distance AND
/// colour difference. That's `O(pixels × radius²)` which is too slow
/// for a 2 048 × 1 536 skin smoothing pass in Dart. This
/// approximation instead:
///
///   1. Computes a cheap separable box blur of the source
///      (`O(pixels × radius)` thanks to running sums).
///   2. For every pixel, measures the luminance difference between
///      source and the blurred version — this is the per-pixel
///      high-frequency detail (pore-level for skin, eye/lip edges for
///      features).
///   3. Blends source ↔ blurred based on that difference: high-detail
///      pixels keep the source (edges preserved), low-detail pixels
///      take the blur (smoothed).
///
/// The visual result is indistinguishable from a proper bilateral at
/// the scales and strengths used by the portrait-smooth pipeline, and
/// it runs in roughly 2× the cost of the box blur it's built on.
///
/// Alpha is copied through from the source untouched.
class EdgePreservingBlur {
  const EdgePreservingBlur._();

  /// Return a new RGBA8 buffer with the same semantics as
  /// [BoxBlur.blurRgba] — smooths low-contrast regions — but
  /// preserves high-contrast edges at [edgeThreshold] or greater
  /// local luminance differential.
  ///
  /// - [radius]: box-blur half-width, same meaning as [BoxBlur].
  /// - [edgeThreshold]: fractional luminance differential at which
  ///   a pixel is treated as a full-strength edge (no blur applied).
  ///   `0.08` (≈ 20/255) is tuned for skin: pores fall below it and
  ///   get smoothed, eyelashes / lip lines / brow edges sit well
  ///   above and get preserved. Lower values preserve more detail;
  ///   higher values smooth more aggressively.
  static Uint8List blurRgba({
    required Uint8List source,
    required int width,
    required int height,
    required int radius,
    double edgeThreshold = 0.08,
  }) {
    if (width <= 0 || height <= 0) {
      throw ArgumentError('width/height must be > 0');
    }
    if (source.length != width * height * 4) {
      throw ArgumentError(
        'source length ${source.length} != ${width * height * 4}',
      );
    }
    if (radius < 0) {
      throw ArgumentError('radius must be >= 0');
    }
    if (edgeThreshold < 0 || edgeThreshold > 1) {
      throw ArgumentError('edgeThreshold must be in [0, 1]');
    }
    if (radius == 0) return Uint8List.fromList(source);

    final blurred = BoxBlur.blurRgba(
      source: source,
      width: width,
      height: height,
      radius: radius,
    );

    final out = Uint8List(source.length);
    final threshFull = (edgeThreshold * 255).clamp(1.0, 255.0);
    final threshHalf = threshFull * 0.5;
    final threshRange = threshFull - threshHalf;

    for (int i = 0; i < source.length; i += 4) {
      final sR = source[i];
      final sG = source[i + 1];
      final sB = source[i + 2];
      final bR = blurred[i];
      final bG = blurred[i + 1];
      final bB = blurred[i + 2];

      // Rec. 709 luminance on both sides.
      final sLum = 0.2126 * sR + 0.7152 * sG + 0.0722 * sB;
      final bLum = 0.2126 * bR + 0.7152 * bG + 0.0722 * bB;
      final diff = (sLum - bLum).abs();

      // Smoothstep blend: diff < half-threshold → fully blurred;
      // diff > full-threshold → fully source; in-between ramps.
      double t;
      if (diff >= threshFull) {
        t = 1.0;
      } else if (diff <= threshHalf) {
        t = 0.0;
      } else {
        final u = (diff - threshHalf) / threshRange;
        t = u * u * (3 - 2 * u);
      }
      final inv = 1.0 - t;

      out[i] = (sR * t + bR * inv).round().clamp(0, 255);
      out[i + 1] = (sG * t + bG * inv).round().clamp(0, 255);
      out[i + 2] = (sB * t + bB * inv).round().clamp(0, 255);
      out[i + 3] = source[i + 3];
    }
    return out;
  }

  /// Mix a fraction of the ORIGINAL [source] pixels back into an
  /// already-smoothed buffer to restore natural micro-texture (skin
  /// pores, fabric grain) and prevent the "plastic" over-smoothed
  /// look that any blur produces at full strength.
  ///
  /// Mathematically this is `out = smoothed * (1-r) + source * r`,
  /// i.e. a linear blend — but the intent is to recover the detail
  /// layer the blur removed, not to re-sharpen edges (which the
  /// edge-preserving blur already keeps). Professional retouching
  /// does the same thing as "frequency separation": smooth the low
  /// frequencies, preserve a portion of the highs.
  ///
  /// - [restoration]: 0..1. `0` = fully smoothed (can look plastic),
  ///   `0.3` is a good default for skin (smooth-but-alive),
  ///   `1` = no smoothing at all.
  static Uint8List restoreDetail({
    required Uint8List smoothed,
    required Uint8List source,
    required double restoration,
  }) {
    if (smoothed.length != source.length) {
      throw ArgumentError(
        'smoothed.length ${smoothed.length} != source.length ${source.length}',
      );
    }
    if (restoration < 0 || restoration > 1) {
      throw ArgumentError('restoration must be in [0, 1]');
    }
    if (restoration == 0.0) return Uint8List.fromList(smoothed);
    if (restoration == 1.0) return Uint8List.fromList(source);

    final out = Uint8List(smoothed.length);
    final keep = 1.0 - restoration;
    for (int i = 0; i < smoothed.length; i += 4) {
      out[i] =
          (smoothed[i] * keep + source[i] * restoration).round().clamp(0, 255);
      out[i + 1] = (smoothed[i + 1] * keep + source[i + 1] * restoration)
          .round()
          .clamp(0, 255);
      out[i + 2] = (smoothed[i + 2] * keep + source[i + 2] * restoration)
          .round()
          .clamp(0, 255);
      out[i + 3] = smoothed[i + 3];
    }
    return out;
  }
}
