import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/material.dart';

/// A named style preset with a pre-computed style bottleneck vector
/// for the Magenta arbitrary style transfer model.
class StylePreset {
  const StylePreset({
    required this.name,
    required this.icon,
    required this.vector,
  });

  final String name;
  final IconData icon;

  /// Style bottleneck vector [1,1,1,100] flattened as Float32List(100).
  final Float32List vector;
}

/// Pre-defined style presets for the Magenta style transfer pipeline.
///
/// The Magenta bottleneck space expects values roughly in [0, 1].
/// These vectors use structured patterns (sparse activations, gradients,
/// smooth curves) to produce distinct visual effects. For true artistic
/// styles (Monet, Starry Night), the prediction model would be needed
/// to compute real vectors from reference images.
class StylePresets {
  const StylePresets._();

  static List<StylePreset> all() => [
        warm(),
        cool(),
        highContrast(),
        pastel(),
        vivid(),
        muted(),
      ];

  /// Warm tones — activates warm-color channels.
  static StylePreset warm() => StylePreset(
        name: 'Warm',
        icon: Icons.wb_sunny,
        vector: _smoothGradient(start: 0.8, end: 0.2),
      );

  /// Cool tones — activates cool-color channels.
  static StylePreset cool() => StylePreset(
        name: 'Cool',
        icon: Icons.ac_unit,
        vector: _smoothGradient(start: 0.2, end: 0.8),
      );

  /// High contrast — sparse strong activations.
  static StylePreset highContrast() => StylePreset(
        name: 'Bold',
        icon: Icons.contrast,
        vector: _sparseActivations(density: 0.3, value: 1.0),
      );

  /// Pastel — all channels at moderate uniform level.
  static StylePreset pastel() => StylePreset(
        name: 'Pastel',
        icon: Icons.palette,
        vector: _uniform(0.5),
      );

  /// Vivid — high activations across all channels.
  static StylePreset vivid() => StylePreset(
        name: 'Vivid',
        icon: Icons.brightness_high,
        vector: _sinusoidal(frequency: 3.0, amplitude: 0.4, offset: 0.6),
      );

  /// Muted — low activations, subdued effect.
  static StylePreset muted() => StylePreset(
        name: 'Muted',
        icon: Icons.brightness_low,
        vector: _uniform(0.15),
      );

  /// Smooth gradient from [start] to [end] across 100 dims.
  static Float32List _smoothGradient({
    required double start,
    required double end,
  }) {
    final v = Float32List(100);
    for (int i = 0; i < 100; i++) {
      v[i] = start + (end - start) * (i / 99.0);
    }
    return v;
  }

  /// Sparse activations: [density] fraction of dims set to [value],
  /// rest are 0.
  static Float32List _sparseActivations({
    required double density,
    required double value,
  }) {
    final v = Float32List(100);
    final rng = Random(42); // deterministic
    for (int i = 0; i < 100; i++) {
      v[i] = rng.nextDouble() < density ? value : 0.0;
    }
    return v;
  }

  /// Uniform value across all 100 dims.
  static Float32List _uniform(double value) {
    final v = Float32List(100);
    for (int i = 0; i < 100; i++) {
      v[i] = value;
    }
    return v;
  }

  /// Sinusoidal wave pattern.
  static Float32List _sinusoidal({
    required double frequency,
    required double amplitude,
    required double offset,
  }) {
    final v = Float32List(100);
    for (int i = 0; i < 100; i++) {
      v[i] = (offset + amplitude * sin(2 * pi * frequency * i / 100))
          .clamp(0.0, 1.0);
    }
    return v;
  }
}
