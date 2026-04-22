import 'package:flutter/foundation.dart';

/// Single-pass sanity statistics for a float alpha mask in `[0, 1]`.
///
/// Every background-removal strategy logs one of these at debug
/// level after inference so pathological outputs surface in the
/// trace instead of silently producing a fully-transparent or
/// fully-opaque cutout. Examples of what a `MaskStats` log tells
/// you when debugging "the AI ran but nothing changed":
///
/// - `min=0, max=0, mean=0`  → model output all zero. Check
///   normalization (MODNet's `[-1,1]` vs RMBG's `[0,1]` input
///   scaling is a common bug), check that the correct output tensor
///   index was read, check the delegate isn't silently misrouting
///   to a zero tensor.
/// - `min=1, max=1, mean=1`  → model output all one. Usually means
///   the preprocessing wiped the input (bad resize), or the mask is
///   being interpreted with inverted polarity.
/// - `mean≈0.5` + high `nonZero`  → healthy soft matte.
/// - `nonZero=0`  → the mask is effectively empty even if `max > 0`
///   (e.g. numerical noise around zero).
///
/// Kept in `ai/inference/` so it lives next to [ImageTensor] and
/// [blendMaskIntoRgba] rather than inside a specific strategy.
@immutable
class MaskStats {
  const MaskStats({
    required this.min,
    required this.max,
    required this.mean,
    required this.nonZero,
    required this.length,
  });

  /// Smallest value observed in the mask.
  final double min;

  /// Largest value observed in the mask.
  final double max;

  /// Arithmetic mean across the whole mask.
  final double mean;

  /// Count of elements greater than `0.01`. Using a small epsilon
  /// instead of strict `> 0` tolerates numerical noise from fp16
  /// delegates.
  final int nonZero;

  /// Total number of elements in the mask. Useful for computing
  /// `nonZero / length` ratios at the caller without re-measuring.
  final int length;

  /// Heuristic: the mask is "effectively empty" — no pixel crosses
  /// the visibility threshold. Used to emit a `warn` log from
  /// adapters so we notice silent-failure models.
  bool get isEffectivelyEmpty => max < 0.01;

  /// Heuristic: the mask is "effectively full" — every pixel is at
  /// or near maximum. Flags the "subject mask covers the whole
  /// image" case which is almost always a bug.
  bool get isEffectivelyFull => min > 0.99;

  /// Fraction of the mask that crosses the visibility threshold.
  /// `nonZero / length` clamped to a safe denominator. Used by
  /// [SkyReplaceService]'s VIII.10 over-coverage check — a mask
  /// covering >60% of the frame is almost never a real sky in
  /// landscape photos and usually means the heuristic latched onto
  /// blue water or a flat blue wall.
  double get coverageRatio => length == 0 ? 0 : nonZero / length;

  /// Build stats in a single pass. Allocates no intermediate lists.
  static MaskStats compute(Float32List mask) {
    if (mask.isEmpty) {
      return const MaskStats(min: 0, max: 0, mean: 0, nonZero: 0, length: 0);
    }
    double lo = mask[0];
    double hi = mask[0];
    double sum = 0;
    int nz = 0;
    for (var i = 0; i < mask.length; i++) {
      final v = mask[i];
      if (v < lo) lo = v;
      if (v > hi) hi = v;
      sum += v;
      if (v > 0.01) nz++;
    }
    return MaskStats(
      min: lo,
      max: hi,
      mean: sum / mask.length,
      nonZero: nz,
      length: mask.length,
    );
  }

  /// Structured map form for [AppLogger] so every adapter emits the
  /// same shape. Keys are short so JSON rendering stays compact.
  Map<String, Object?> toLogMap() => {
        'min': min.toStringAsFixed(3),
        'max': max.toStringAsFixed(3),
        'mean': mean.toStringAsFixed(3),
        'nonZero': nonZero,
        'length': length,
      };
}
