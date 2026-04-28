import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';

import 'package:image_editor/engine/layers/brush_pressure_mapping.dart';

/// Phase XVI.41 — pin the pressure → opacity and tilt → hardness math
/// the draw mode overlay calls on stroke end. The two key invariants
/// (no-signal samples don't modulate, low pressure has a visible
/// floor) protect non-stylus pointers from looking different than
/// pre-XVI.41.
void main() {
  group('BrushPressureMapping (XVI.41)', () {
    const mapping = BrushPressureMapping();

    test('empty samples leave opacity unchanged (touch / mouse fallback)',
        () {
      // No PointerEvent samples gathered → mapping must not modulate.
      expect(mapping.applyToOpacity(0.8, const []), 0.8);
    });

    test('all-1.0 pressure samples leave opacity unchanged', () {
      // Touch / mouse defaults pressure to 1.0; treating that as
      // "no stylus" preserves the pre-XVI.41 visual exactly.
      final samples = List<double>.filled(10, 1.0);
      expect(mapping.applyToOpacity(0.8, samples), 0.8);
    });

    test('half pressure scales opacity to roughly 65 %', () {
      // factor = 0.3 + 0.7 * 0.5 = 0.65
      final samples = List<double>.filled(10, 0.5);
      expect(mapping.applyToOpacity(1.0, samples), closeTo(0.65, 1e-6));
    });

    test('zero pressure floors opacity at minOpacityFactor', () {
      // factor = minOpacityFactor (0.3 by default)
      final samples = List<double>.filled(5, 0.0);
      expect(mapping.applyToOpacity(1.0, samples), closeTo(0.3, 1e-6));
    });

    test('mean is computed across all samples (not min/max)', () {
      // Faint start, hard middle, faint end — average should pick up
      // the middle, but not as much as a max.
      final samples = <double>[0.1, 0.1, 0.9, 0.9, 0.9, 0.1, 0.1];
      final mean = samples.reduce((a, b) => a + b) / samples.length;
      // factor = 0.3 + 0.7 * mean
      final expected = 1.0 * (0.3 + 0.7 * mean);
      expect(
        mapping.applyToOpacity(1.0, samples),
        closeTo(expected, 1e-6),
      );
    });

    test('opacity result is clamped to [0, 1]', () {
      // Even with full pressure we should never exceed the base.
      expect(mapping.applyToOpacity(1.5, [0.5]), lessThanOrEqualTo(1.0));
      expect(mapping.applyToOpacity(0.0, [1.0]), greaterThanOrEqualTo(0.0));
    });

    test('empty tilt samples leave hardness unchanged', () {
      expect(mapping.applyToHardness(0.7, const []), 0.7);
    });

    test('zero tilt leaves hardness unchanged (no signal)', () {
      final samples = List<double>.filled(5, 0.0);
      expect(mapping.applyToHardness(0.7, samples), 0.7);
    });

    test('full tilt softens by maxTiltSoftening', () {
      // tilt = π/2, softening = 0.5 → hardness * 0.5
      final samples = List<double>.filled(5, math.pi / 2);
      expect(
        mapping.applyToHardness(1.0, samples),
        closeTo(0.5, 1e-6),
      );
    });

    test('half tilt softens proportionally', () {
      // tilt = π/4 → tiltFactor = 0.5 → softening = 0.25 → hardness * 0.75
      final samples = List<double>.filled(5, math.pi / 4);
      expect(
        mapping.applyToHardness(1.0, samples),
        closeTo(0.75, 1e-6),
      );
    });

    test('hardness result is clamped to [0, 1]', () {
      // Pathological: passing a hardness > 1 still clamps the output.
      expect(mapping.applyToHardness(1.5, [math.pi / 2]),
          lessThanOrEqualTo(1.0));
    });

    test('custom minOpacityFactor is honoured', () {
      const aggressive = BrushPressureMapping(minOpacityFactor: 0.0);
      // factor = 0 + 1 * 0 = 0
      final samples = List<double>.filled(5, 0.0);
      expect(aggressive.applyToOpacity(1.0, samples), closeTo(0.0, 1e-6));
    });
  });
}
