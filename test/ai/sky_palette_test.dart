import 'package:flutter_test/flutter_test.dart';

import 'package:image_editor/ai/inference/sky_palette.dart';
import 'package:image_editor/ai/services/sky_replace/sky_preset.dart';

void main() {
  group('SkyPreset', () {
    test('every preset has a non-empty label + description', () {
      for (final p in SkyPreset.values) {
        expect(p.label.isNotEmpty, true, reason: 'no label for ${p.name}');
        expect(p.description.isNotEmpty, true,
            reason: 'no description for ${p.name}');
      }
    });

    test('fromName round-trip is stable for every preset', () {
      for (final p in SkyPreset.values) {
        expect(SkyPresetX.fromName(p.persistKey), p);
      }
    });

    test('fromName falls back to clearBlue for unknown names', () {
      expect(SkyPresetX.fromName(null), SkyPreset.clearBlue);
      expect(SkyPresetX.fromName('definitely-not-a-preset'),
          SkyPreset.clearBlue);
    });

    test('enum has the 4 expected values in order', () {
      // Enum order shows up in picker iteration + analytics; test
      // locks the sequence so nobody accidentally rearranges.
      expect(SkyPreset.values, [
        SkyPreset.clearBlue,
        SkyPreset.sunset,
        SkyPreset.night,
        SkyPreset.dramatic,
      ]);
    });
  });

  group('SkyPalette.generate — validation', () {
    test('rejects non-positive dimensions', () {
      expect(
        () => SkyPalette.generate(
          preset: SkyPreset.clearBlue,
          width: 0,
          height: 10,
        ),
        throwsArgumentError,
      );
    });
  });

  group('SkyPalette.generate — every preset', () {
    test('returns a correctly sized buffer', () {
      for (final p in SkyPreset.values) {
        final out = SkyPalette.generate(
          preset: p,
          width: 8,
          height: 8,
        );
        expect(out.length, 8 * 8 * 4,
            reason: '${p.name} must fill a 4-byte RGBA pixel grid');
      }
    });

    test('alpha is always 255', () {
      for (final p in SkyPreset.values) {
        final out = SkyPalette.generate(
          preset: p,
          width: 8,
          height: 8,
        );
        for (int i = 3; i < out.length; i += 4) {
          expect(out[i], 255,
              reason: '${p.name} must produce fully opaque pixels');
        }
      }
    });

    test('output is deterministic', () {
      for (final p in SkyPreset.values) {
        final a = SkyPalette.generate(preset: p, width: 6, height: 6);
        final b = SkyPalette.generate(preset: p, width: 6, height: 6);
        expect(a, orderedEquals(b),
            reason: '${p.name} must be byte-identical across runs');
      }
    });
  });

  group('SkyPalette.generate — preset color characteristics', () {
    test('clearBlue top pixel is more blue than red', () {
      final out = SkyPalette.generate(
        preset: SkyPreset.clearBlue,
        width: 4,
        height: 4,
      );
      // Pixel (0,0): top-row = top stop of gradient.
      final r = out[0];
      final b = out[2];
      expect(b, greaterThan(r), reason: 'blue sky top should be blue-dominant');
    });

    test('night preset is darker than clearBlue', () {
      final night = SkyPalette.generate(
        preset: SkyPreset.night,
        width: 4,
        height: 4,
      );
      final blue = SkyPalette.generate(
        preset: SkyPreset.clearBlue,
        width: 4,
        height: 4,
      );
      // Mean brightness over the whole buffer.
      int nightSum = 0;
      int blueSum = 0;
      for (int i = 0; i < night.length; i += 4) {
        nightSum += night[i] + night[i + 1] + night[i + 2];
        blueSum += blue[i] + blue[i + 1] + blue[i + 2];
      }
      expect(nightSum, lessThan(blueSum));
    });

    test('sunset top row is warm (R > B)', () {
      final out = SkyPalette.generate(
        preset: SkyPreset.sunset,
        width: 4,
        height: 4,
      );
      final r = out[0];
      final b = out[2];
      expect(r, greaterThan(b),
          reason: 'sunset starts warm orange, not blue');
    });

    test('dramatic preset has pixel-to-pixel variation (not flat)', () {
      final out = SkyPalette.generate(
        preset: SkyPreset.dramatic,
        width: 16,
        height: 16,
      );
      // Compare adjacent pixels in the same row — noise pattern
      // should produce different values.
      int differences = 0;
      for (int y = 0; y < 16; y++) {
        for (int x = 1; x < 16; x++) {
          final idxA = (y * 16 + x - 1) * 4;
          final idxB = (y * 16 + x) * 4;
          if (out[idxA] != out[idxB]) differences++;
        }
      }
      expect(differences, greaterThan(100),
          reason: 'dramatic should have visible noise texture');
    });

    test('clearBlue preset produces a flat horizontal gradient', () {
      final out = SkyPalette.generate(
        preset: SkyPreset.clearBlue,
        width: 16,
        height: 16,
      );
      // Within any row, every pixel must have the same RGB
      // values (horizontal rows are constant).
      for (int y = 0; y < 16; y++) {
        final firstIdx = (y * 16) * 4;
        final r = out[firstIdx];
        final g = out[firstIdx + 1];
        final b = out[firstIdx + 2];
        for (int x = 1; x < 16; x++) {
          final idx = (y * 16 + x) * 4;
          expect(out[idx], r);
          expect(out[idx + 1], g);
          expect(out[idx + 2], b);
        }
      }
    });
  });
}
