import 'dart:math' as math;

/// Phase XVI.41 — pure-Dart math that maps captured stylus pressure +
/// tilt into per-stroke opacity / hardness modulation. Lives in the
/// engine layer (not the widget) so the same mapping can be unit-
/// tested without spinning up a Flutter `Listener` widget tree.
///
/// Inputs come straight from `PointerEvent.pressure` (in `[0, 1]` for
/// stylus, default `1.0` for touch / mouse) and `PointerEvent.tilt`
/// (in radians, in `[0, π/2]`, default `0.0` when the device doesn't
/// support it).
///
/// **Backward compatibility**: when no pressure / tilt samples are
/// recorded — e.g. the user is on a touch-only device, or the brush
/// captures came from pre-XVI.41 saved sessions — the mapping
/// returns the supplied base values unchanged. So an existing UI
/// that calls `applyToOpacity(baseOpacity, samples)` with `samples =
/// const []` rounds back to `baseOpacity` exactly.
class BrushPressureMapping {
  const BrushPressureMapping({
    this.minOpacityFactor = 0.3,
    this.maxTiltSoftening = 0.5,
  });

  /// Floor of the pressure-derived opacity multiplier. With the
  /// default 0.3, a faint stylus touch (pressure ≈ 0.05) lands at
  /// 30% opacity instead of disappearing entirely — Procreate's
  /// "low-pressure floor" trick that keeps strokes visible even
  /// when the user is barely touching the screen.
  final double minOpacityFactor;

  /// Maximum amount tilt can soften the stroke (1 - hardness). With
  /// the default 0.5, a fully-tilted pencil (~π/2 from vertical)
  /// halves the effective hardness, matching the perceptual
  /// behaviour of dragging the side of an Apple Pencil along the
  /// page.
  final double maxTiltSoftening;

  /// Returns the opacity to record on the stroke. Mean-pressure
  /// across the gathered samples gates the modulation, with a soft
  /// floor so faint strokes remain visible.
  ///
  /// Empty samples → returns [baseOpacity] verbatim (no modulation).
  /// Mean pressure of 1.0 (touch / mouse default) → also returns
  /// [baseOpacity] verbatim, so non-stylus pointers don't accidentally
  /// look "lighter" than they used to.
  double applyToOpacity(double baseOpacity, List<double> pressureSamples) {
    final pressure = _meanPressure(pressureSamples);
    if (pressure == null) return baseOpacity;
    // Pressure 1.0 → factor 1.0 → no change. Pressure 0.0 → factor
    // [minOpacityFactor]. Linear in between.
    final factor = minOpacityFactor + (1 - minOpacityFactor) * pressure;
    return (baseOpacity * factor).clamp(0.0, 1.0);
  }

  /// Returns the hardness to record on the stroke. Mean tilt
  /// softens the edge — a pencil dragged on its side produces a
  /// fuzzier mark than one held vertically.
  ///
  /// Empty samples → returns [baseHardness] verbatim. Tilt 0 (the
  /// no-tilt default) also returns [baseHardness] verbatim.
  double applyToHardness(double baseHardness, List<double> tiltSamples) {
    final tilt = _meanTilt(tiltSamples);
    if (tilt == null) return baseHardness;
    // tilt = π/2 → softening factor = maxTiltSoftening (e.g. 0.5).
    // tilt = 0    → softening factor = 0 (no softening).
    final tiltFactor = (tilt / (math.pi / 2)).clamp(0.0, 1.0);
    final softening = tiltFactor * maxTiltSoftening;
    return (baseHardness * (1 - softening)).clamp(0.0, 1.0);
  }

  double? _meanPressure(List<double> samples) {
    if (samples.isEmpty) return null;
    var sum = 0.0;
    for (final s in samples) {
      sum += s.clamp(0.0, 1.0);
    }
    final mean = sum / samples.length;
    // Touch / mouse defaults to 1.0; treat that as "no stylus signal"
    // so non-stylus pointers don't degrade the existing behaviour.
    if ((mean - 1.0).abs() < 1e-3) return null;
    return mean;
  }

  double? _meanTilt(List<double> samples) {
    if (samples.isEmpty) return null;
    var sum = 0.0;
    for (final s in samples) {
      sum += s.clamp(0.0, math.pi / 2);
    }
    final mean = sum / samples.length;
    if (mean < 1e-3) return null; // no tilt signal
    return mean;
  }
}
