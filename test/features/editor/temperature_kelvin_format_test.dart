import 'package:flutter_test/flutter_test.dart';

import 'package:image_editor/features/editor/presentation/widgets/lightroom_panel.dart';

/// Phase XVI.31 — pin the temperature → Kelvin display mapping the
/// LightroomPanel uses when `session.temperatureExif.mode == kelvin`.
///
/// The formatter mirrors `whiteBalanceMultiplier` in
/// `shaders/color_grading.frag` so the displayed Kelvin matches the
/// pixel-level effect:
///   slider = 0   → baseline Kelvin (e.g. 6500 K at D65)
///   slider > 0   → warmer = lower Kelvin (delta × 4500)
///   slider < 0   → cooler = higher Kelvin (delta × 5500)
///
/// The pivot baseline comes from EXIF (Fujifilm/Olympus makernote) or
/// defaults to D65 (6500 K) when only the standard `EXIF WhiteBalance`
/// tag is present.
void main() {
  group('formatTemperatureKelvin (XVI.31)', () {
    test('slider=0 displays the exact baseline', () {
      expect(formatTemperatureKelvin(0, 6500), '6500 K');
      expect(formatTemperatureKelvin(0, 5500), '5500 K');
    });

    test('positive slider drops Kelvin (warmer = lower K)', () {
      // +0.5 against D65: 6500 - 0.5 * 4500 = 4250 K
      expect(formatTemperatureKelvin(0.5, 6500), '4250 K');
      // +1.0 hits the 2000 K floor (matches shader's 2000..12000 clamp).
      expect(formatTemperatureKelvin(1.0, 6500), '2000 K');
    });

    test('negative slider raises Kelvin (cooler = higher K)', () {
      // -0.5 against D65: 6500 + 0.5 * 5500 = 9250 K
      expect(formatTemperatureKelvin(-0.5, 6500), '9250 K');
      // -1.0 hits the 12000 K ceiling.
      expect(formatTemperatureKelvin(-1.0, 6500), '12000 K');
    });

    test('non-D65 baseline pivots correctly', () {
      // Fujifilm scene at 4800 K — slider=0 displays the camera's
      // recorded baseline, not D65.
      expect(formatTemperatureKelvin(0, 4800), '4800 K');
      // +0.2 warmer of 4800: 4800 - 0.2*4500 = 3900 K
      expect(formatTemperatureKelvin(0.2, 4800), '3900 K');
    });

    test('extreme slider values are clamped to the safe Kelvin window', () {
      // Even past +1, we clamp to 2000 K — the shader clamps the same
      // way so the displayed value can never disagree with the pixel
      // result.
      expect(formatTemperatureKelvin(2.0, 6500), '2000 K');
      expect(formatTemperatureKelvin(-2.0, 6500), '12000 K');
    });
  });
}
