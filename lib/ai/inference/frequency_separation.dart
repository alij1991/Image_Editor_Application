import 'dart:typed_data';

import 'box_blur.dart';

/// Phase XVI.48 — explicit frequency-separation math used by the
/// portrait smooth pipeline.
///
/// Frequency separation is the photographer's standard skin-retouching
/// technique: split an image into a low-frequency layer (smooth tone +
/// colour) and a high-frequency layer (pores + fine detail), retouch
/// the low-frequency layer, then recombine. The result reads as
/// "smoothed but alive" — the high-frequency texture survives, so skin
/// doesn't look plastic.
///
/// Pre-XVI.48 the same math lived inside `EdgePreservingBlur.blurRgba`
/// + `restoreDetail` as two independent helpers. Pulling them into one
/// named module makes the photo-retouching contract obvious to future
/// readers and keeps the maths testable in isolation.
///
/// API summary:
///   - [split] takes an RGBA buffer and a low-pass radius; returns the
///     low-frequency layer (a box-blurred RGBA buffer) and the high-
///     frequency residual (signed deltas, packed as RGBA so the same
///     stride is reusable).
///   - [recombine] takes the two layers + per-layer mix weights and
///     produces the final RGBA buffer. Defaults preserve both layers
///     verbatim — i.e. `recombine(split(x).low, split(x).high) == x`
///     up to clamping rounding error.
///   - [smoothLowFrequency] is the user-facing convenience: split,
///     keep the low-frequency layer (smoothed), mix in a fraction of
///     the high-frequency layer, and recombine. The recipe portraits
///     ship today.
class FrequencySeparation {
  const FrequencySeparation._();

  /// Split [source] into a low-frequency layer (box-blurred at
  /// [lowPassRadius]) and a high-frequency residual (per-channel
  /// signed delta = source - lowPass). The residual is stored as
  /// RGBA8 with values centered on 128 (so 128 == zero delta), which
  /// keeps the buffer addressable with the same stride as the source
  /// and avoids a separate `Int8List` shape.
  ///
  /// Alpha is copied through from the source; the low-pass alpha
  /// matches the source alpha so a downstream mask blend doesn't
  /// double-darken transparent pixels.
  static FrequencySplit split({
    required Uint8List source,
    required int width,
    required int height,
    required int lowPassRadius,
  }) {
    if (source.length != width * height * 4) {
      throw ArgumentError(
        'source length ${source.length} != ${width * height * 4}',
      );
    }
    if (lowPassRadius < 0) {
      throw ArgumentError('lowPassRadius must be >= 0');
    }
    if (lowPassRadius == 0) {
      // Identity split: low layer == source, high layer is zero
      // (encoded as 128 across RGB).
      final low = Uint8List.fromList(source);
      final high = Uint8List(source.length);
      for (var i = 0; i < high.length; i += 4) {
        high[i] = 128;
        high[i + 1] = 128;
        high[i + 2] = 128;
        high[i + 3] = source[i + 3];
      }
      return FrequencySplit(low: low, high: high);
    }
    final low = BoxBlur.blurRgba(
      source: source,
      width: width,
      height: height,
      radius: lowPassRadius,
    );
    final high = Uint8List(source.length);
    for (var i = 0; i < source.length; i += 4) {
      high[i] = (source[i] - low[i] + 128).clamp(0, 255).toInt();
      high[i + 1] = (source[i + 1] - low[i + 1] + 128).clamp(0, 255).toInt();
      high[i + 2] = (source[i + 2] - low[i + 2] + 128).clamp(0, 255).toInt();
      high[i + 3] = source[i + 3];
    }
    return FrequencySplit(low: low, high: high);
  }

  /// Recombine [low] and [high] into a single RGBA buffer.
  ///
  /// `lowFactor == 1.0 && highFactor == 1.0` rebuilds the original
  /// (identity case). `highFactor < 1.0` damps the high-frequency
  /// detail — the standard "smooth-but-alive" portrait recipe. Alpha
  /// is taken from [low] (which carries the original alpha after
  /// [split]).
  static Uint8List recombine({
    required Uint8List low,
    required Uint8List high,
    double lowFactor = 1.0,
    double highFactor = 1.0,
  }) {
    if (low.length != high.length) {
      throw ArgumentError(
        'low/high length mismatch (${low.length} vs ${high.length})',
      );
    }
    final out = Uint8List(low.length);
    for (var i = 0; i < low.length; i += 4) {
      // high is centered on 128; subtract to recover signed delta.
      final dr = high[i] - 128;
      final dg = high[i + 1] - 128;
      final db = high[i + 2] - 128;
      out[i] = (low[i] * lowFactor + dr * highFactor).round().clamp(0, 255);
      out[i + 1] =
          (low[i + 1] * lowFactor + dg * highFactor).round().clamp(0, 255);
      out[i + 2] =
          (low[i + 2] * lowFactor + db * highFactor).round().clamp(0, 255);
      out[i + 3] = low[i + 3];
    }
    return out;
  }

  /// One-shot helper: split, keep the low-pass smoothed layer, mix in
  /// `highFactor` of the high-pass detail, and recombine. Equivalent
  /// to a manual `split` + `recombine(highFactor: ...)` pair but
  /// allocates one fewer intermediate buffer.
  ///
  /// `highFactor`:
  ///   - `0.0` = fully smoothed (plastic skin)
  ///   - `0.7` = portrait-friendly default — visible texture, smooth tone
  ///   - `1.0` = no smoothing (identity)
  static Uint8List smoothLowFrequency({
    required Uint8List source,
    required int width,
    required int height,
    required int lowPassRadius,
    required double highFactor,
  }) {
    if (highFactor < 0 || highFactor > 1) {
      throw ArgumentError('highFactor must be in [0, 1]');
    }
    if (lowPassRadius == 0 || highFactor == 1.0) {
      return Uint8List.fromList(source);
    }
    final split = FrequencySeparation.split(
      source: source,
      width: width,
      height: height,
      lowPassRadius: lowPassRadius,
    );
    return recombine(
      low: split.low,
      high: split.high,
      highFactor: highFactor,
    );
  }
}

/// The two layers produced by [FrequencySeparation.split].
class FrequencySplit {
  const FrequencySplit({required this.low, required this.high});

  /// Low-pass (smooth tone + colour) RGBA buffer at the source
  /// resolution.
  final Uint8List low;

  /// High-pass (texture / pores) RGBA buffer at the source resolution.
  /// Per-channel values are centered on 128 so the buffer fits in
  /// uint8 without sign-extension headaches.
  final Uint8List high;
}
