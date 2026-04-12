import 'dart:typed_data';

import '../services/sky_replace/sky_preset.dart';

/// RGB color stops for a single sky preset. Used both by the
/// [SkyPalette] pixel generator and the picker-sheet swatch chip
/// so both stay in perfect sync when we tweak a preset's color.
///
/// The [middle] stop is `null` for two-stop gradients and the
/// middle color for the three-stop sunset preset. [midPosition]
/// is the vertical fraction (0=top, 1=bottom) at which the middle
/// color lands, matching the triple-stop generator's hardcoded
/// constant.
class SkyPaletteStops {
  const SkyPaletteStops({
    required this.top,
    required this.bottom,
    this.middle,
    this.midPosition = 0.45,
  });

  final SkyColor top;
  final SkyColor bottom;
  final SkyColor? middle;
  final double midPosition;

  bool get hasMiddle => middle != null;
}

/// Immutable RGB triple used by [SkyPaletteStops]. `const` so the
/// stop table below can be built at compile time.
class SkyColor {
  const SkyColor(this.r, this.g, this.b);
  final int r;
  final int g;
  final int b;
}

/// Deterministic procedural sky RGBA8 generators for Phase 9g.
///
/// Each [SkyPreset] maps to a pure-Dart function that paints a
/// vertical gradient at the requested dimensions. Deterministic
/// means: same preset + same width/height always yields the same
/// bytes, which lets us unit-test the generator without loading
/// any assets.
///
/// Generated buffers are full opaque (`alpha=255`) — the sky mask
/// drives compositing, so alpha here isn't meaningful. Dimensions
/// match the source image so no resize is needed before blending.
class SkyPalette {
  const SkyPalette._();

  /// Authoritative table of every preset's color stops. The
  /// [generate] method AND the picker-sheet swatch chip both read
  /// from this map so a single edit propagates everywhere. Drift
  /// between palette and swatch is guarded by a test that asserts
  /// the first/last generated pixels match the declared stops.
  static const Map<SkyPreset, SkyPaletteStops> stopsByPreset = {
    SkyPreset.clearBlue: SkyPaletteStops(
      top: SkyColor(90, 160, 230),
      bottom: SkyColor(200, 230, 255),
    ),
    SkyPreset.sunset: SkyPaletteStops(
      top: SkyColor(255, 180, 100),
      middle: SkyColor(255, 120, 80),
      bottom: SkyColor(80, 60, 120),
      midPosition: 0.45,
    ),
    SkyPreset.night: SkyPaletteStops(
      top: SkyColor(8, 12, 32),
      bottom: SkyColor(40, 55, 100),
    ),
    SkyPreset.dramatic: SkyPaletteStops(
      top: SkyColor(55, 65, 85),
      bottom: SkyColor(180, 170, 150),
    ),
  };

  /// Produce a fresh `width*height*4` RGBA8 buffer for [preset].
  /// Throws [ArgumentError] on non-positive dimensions.
  static Uint8List generate({
    required SkyPreset preset,
    required int width,
    required int height,
  }) {
    if (width <= 0 || height <= 0) {
      throw ArgumentError('width and height must be > 0');
    }
    final stops = stopsByPreset[preset]!;
    switch (preset) {
      case SkyPreset.clearBlue:
      case SkyPreset.night:
        return _gradient(
          width: width,
          height: height,
          top: _Rgb(stops.top.r, stops.top.g, stops.top.b),
          bottom: _Rgb(stops.bottom.r, stops.bottom.g, stops.bottom.b),
        );
      case SkyPreset.sunset:
        final middle = stops.middle!;
        return _tripleStop(
          width: width,
          height: height,
          top: _Rgb(stops.top.r, stops.top.g, stops.top.b),
          middle: _Rgb(middle.r, middle.g, middle.b),
          bottom: _Rgb(stops.bottom.r, stops.bottom.g, stops.bottom.b),
          midPosition: stops.midPosition,
        );
      case SkyPreset.dramatic:
        return _dramatic(
          width: width,
          height: height,
          top: _Rgb(stops.top.r, stops.top.g, stops.top.b),
          bottom: _Rgb(stops.bottom.r, stops.bottom.g, stops.bottom.b),
        );
    }
  }

  // ----- internals ---------------------------------------------------------

  /// Two-stop vertical gradient with smoothstep interpolation so
  /// the top and bottom bands don't visibly banded at low colour
  /// depth.
  static Uint8List _gradient({
    required int width,
    required int height,
    required _Rgb top,
    required _Rgb bottom,
  }) {
    final out = Uint8List(width * height * 4);
    for (int y = 0; y < height; y++) {
      final t = height <= 1 ? 0.0 : y / (height - 1);
      final s = _smoothstep(t);
      final r = (top.r + (bottom.r - top.r) * s).round();
      final g = (top.g + (bottom.g - top.g) * s).round();
      final b = (top.b + (bottom.b - top.b) * s).round();
      for (int x = 0; x < width; x++) {
        final idx = (y * width + x) * 4;
        out[idx] = r;
        out[idx + 1] = g;
        out[idx + 2] = b;
        out[idx + 3] = 255;
      }
    }
    return out;
  }

  /// Three-stop vertical gradient. [midPosition] is the vertical
  /// fraction (0=top, 1=bottom) where [middle] lands. Matches the
  /// value declared in [SkyPalette.stopsByPreset] so picker
  /// swatches can mirror the real gradient exactly.
  static Uint8List _tripleStop({
    required int width,
    required int height,
    required _Rgb top,
    required _Rgb middle,
    required _Rgb bottom,
    required double midPosition,
  }) {
    final out = Uint8List(width * height * 4);
    final midPoint = midPosition;
    for (int y = 0; y < height; y++) {
      final t = height <= 1 ? 0.0 : y / (height - 1);
      _Rgb c;
      if (t <= midPoint) {
        final u = _smoothstep(t / midPoint);
        c = _Rgb(
          (top.r + (middle.r - top.r) * u).round(),
          (top.g + (middle.g - top.g) * u).round(),
          (top.b + (middle.b - top.b) * u).round(),
        );
      } else {
        final u = _smoothstep((t - midPoint) / (1 - midPoint));
        c = _Rgb(
          (middle.r + (bottom.r - middle.r) * u).round(),
          (middle.g + (bottom.g - middle.g) * u).round(),
          (middle.b + (bottom.b - middle.b) * u).round(),
        );
      }
      for (int x = 0; x < width; x++) {
        final idx = (y * width + x) * 4;
        out[idx] = c.r;
        out[idx + 1] = c.g;
        out[idx + 2] = c.b;
        out[idx + 3] = 255;
      }
    }
    return out;
  }

  /// Overcast-with-cloud-texture look. Starts from a two-stop base
  /// gradient and modulates each row by a cheap deterministic
  /// pseudo-random pattern so the output reads as "cloudy" rather
  /// than "solid flat gradient". Seeded by pixel coordinates so
  /// the result is still 100% deterministic.
  static Uint8List _dramatic({
    required int width,
    required int height,
    required _Rgb top,
    required _Rgb bottom,
  }) {
    final out = _gradient(
      width: width,
      height: height,
      top: top,
      bottom: bottom,
    );
    // Add a low-frequency deterministic pattern across the RGB
    // channels to suggest cloud banding. Using `(x*37 + y*17)` as a
    // cheap hash keeps the noise stable across runs.
    const amp = 30; // ±30 on R/G/B
    for (int y = 0; y < height; y++) {
      for (int x = 0; x < width; x++) {
        final idx = (y * width + x) * 4;
        final hash = ((x * 37 + y * 17) & 0xff) / 255.0;
        final delta = ((hash * 2 - 1) * amp).round();
        out[idx] = _clamp(out[idx] + delta);
        out[idx + 1] = _clamp(out[idx + 1] + delta);
        out[idx + 2] = _clamp(out[idx + 2] + delta);
      }
    }
    return out;
  }

  static double _smoothstep(double t) {
    if (t <= 0) return 0;
    if (t >= 1) return 1;
    return t * t * (3 - 2 * t);
  }

  static int _clamp(int v) {
    if (v < 0) return 0;
    if (v > 255) return 255;
    return v;
  }
}

class _Rgb {
  const _Rgb(this.r, this.g, this.b);
  final int r;
  final int g;
  final int b;
}
