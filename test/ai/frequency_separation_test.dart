import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:image_editor/ai/inference/frequency_separation.dart';

/// Phase XVI.48 — pin the frequency-separation maths used by the
/// portrait smooth pipeline. Three invariants matter:
///
///   1. `recombine(split(x).low, split(x).high)` is the identity
///      transform up to clamping rounding (round-trip fidelity).
///   2. `highFactor == 0` produces the box-blurred low layer
///      verbatim (full smooth — the "plastic" extreme).
///   3. `lowPassRadius == 0` produces the source verbatim (no smooth
///      requested — no work done).
void main() {
  Uint8List makeImage(int width, int height,
      {int rgb = 100, int alpha = 255}) {
    final out = Uint8List(width * height * 4);
    for (var i = 0; i < out.length; i += 4) {
      out[i] = rgb;
      out[i + 1] = rgb;
      out[i + 2] = rgb;
      out[i + 3] = alpha;
    }
    return out;
  }

  /// A 4×4 image with a sharp luminance step in the middle so the
  /// box blur produces visible smoothing and the high-frequency
  /// residual carries the step.
  Uint8List makeStepImage() {
    final out = Uint8List(4 * 4 * 4);
    for (var y = 0; y < 4; y++) {
      for (var x = 0; x < 4; x++) {
        final i = (y * 4 + x) * 4;
        final v = x < 2 ? 50 : 200;
        out[i] = v;
        out[i + 1] = v;
        out[i + 2] = v;
        out[i + 3] = 255;
      }
    }
    return out;
  }

  group('FrequencySeparation.split (XVI.48)', () {
    test('zero radius produces an identity-low + zero-high split', () {
      final src = makeImage(4, 4);
      final split = FrequencySeparation.split(
        source: src,
        width: 4,
        height: 4,
        lowPassRadius: 0,
      );
      // Low layer == source byte-for-byte.
      expect(split.low, equals(src));
      // High layer is centered on 128 (the zero-delta encoding) for
      // every RGB component.
      for (var i = 0; i < split.high.length; i += 4) {
        expect(split.high[i], 128);
        expect(split.high[i + 1], 128);
        expect(split.high[i + 2], 128);
        expect(split.high[i + 3], src[i + 3]);
      }
    });

    test('split + recombine round-trips a flat image', () {
      final src = makeImage(8, 8, rgb: 117);
      final split = FrequencySeparation.split(
        source: src,
        width: 8,
        height: 8,
        lowPassRadius: 2,
      );
      final back = FrequencySeparation.recombine(
        low: split.low,
        high: split.high,
      );
      // Flat image → low == source, high is zero-centered, so the
      // recombine must reproduce the source exactly.
      expect(back, equals(src));
    });

    test('high-frequency layer carries the step edge for a step image', () {
      final src = makeStepImage();
      final split = FrequencySeparation.split(
        source: src,
        width: 4,
        height: 4,
        lowPassRadius: 1,
      );
      // The pixel exactly at the boundary will see the largest
      // delta from the smoothed mean. Find an interior pixel on the
      // dark side adjacent to the step and check its high value
      // sits below 128 (negative delta).
      const iLeft = (1 * 4 + 1) * 4;
      expect(split.high[iLeft], lessThan(128),
          reason: 'dark-side high should be a negative delta');
      // Mirror on the right side.
      const iRight = (1 * 4 + 2) * 4;
      expect(split.high[iRight], greaterThan(128),
          reason: 'bright-side high should be a positive delta');
    });

    test('alpha is preserved end-to-end', () {
      final src = makeImage(4, 4, alpha: 200);
      final split = FrequencySeparation.split(
        source: src,
        width: 4,
        height: 4,
        lowPassRadius: 1,
      );
      for (var i = 3; i < split.low.length; i += 4) {
        expect(split.low[i], 200);
        expect(split.high[i], 200);
      }
    });
  });

  group('FrequencySeparation.recombine (XVI.48)', () {
    test('identity factors rebuild the source on a step image', () {
      final src = makeStepImage();
      final split = FrequencySeparation.split(
        source: src,
        width: 4,
        height: 4,
        lowPassRadius: 1,
      );
      final back = FrequencySeparation.recombine(
        low: split.low,
        high: split.high,
      );
      // Box blur introduces tiny rounding; allow ±1 per channel.
      for (var i = 0; i < src.length; i++) {
        expect((back[i] - src[i]).abs(), lessThanOrEqualTo(1),
            reason: 'recombine drifted at byte $i');
      }
    });

    test('highFactor=0 collapses to the smoothed low layer', () {
      final src = makeStepImage();
      final split = FrequencySeparation.split(
        source: src,
        width: 4,
        height: 4,
        lowPassRadius: 1,
      );
      final smoothed = FrequencySeparation.recombine(
        low: split.low,
        high: split.high,
        highFactor: 0.0,
      );
      // Result is the low layer with the source's alpha.
      for (var i = 0; i < smoothed.length; i += 4) {
        expect(smoothed[i], split.low[i]);
        expect(smoothed[i + 1], split.low[i + 1]);
        expect(smoothed[i + 2], split.low[i + 2]);
        expect(smoothed[i + 3], split.low[i + 3]);
      }
    });
  });

  group('FrequencySeparation.smoothLowFrequency (XVI.48)', () {
    test('zero radius is a no-op', () {
      final src = makeStepImage();
      final out = FrequencySeparation.smoothLowFrequency(
        source: src,
        width: 4,
        height: 4,
        lowPassRadius: 0,
        highFactor: 0.0,
      );
      expect(out, equals(src));
    });

    test('highFactor=1 is a no-op even with radius > 0', () {
      final src = makeStepImage();
      final out = FrequencySeparation.smoothLowFrequency(
        source: src,
        width: 4,
        height: 4,
        lowPassRadius: 2,
        highFactor: 1.0,
      );
      expect(out, equals(src));
    });

    test('partial highFactor blends between source and low', () {
      final src = makeStepImage();
      final out = FrequencySeparation.smoothLowFrequency(
        source: src,
        width: 4,
        height: 4,
        lowPassRadius: 1,
        highFactor: 0.5,
      );
      // For interior pixels (not on the step), the blurred low layer
      // is close to the source value, so the result should also be
      // close to the source. A pixel ON the step gets a softer
      // transition than the original.
      // We just verify the output isn't equal to either extreme —
      // it's a real blend.
      expect(out, isNot(equals(src)));
    });

    test('rejects out-of-range highFactor', () {
      final src = makeStepImage();
      expect(
        () => FrequencySeparation.smoothLowFrequency(
          source: src,
          width: 4,
          height: 4,
          lowPassRadius: 1,
          highFactor: -0.1,
        ),
        throwsArgumentError,
      );
      expect(
        () => FrequencySeparation.smoothLowFrequency(
          source: src,
          width: 4,
          height: 4,
          lowPassRadius: 1,
          highFactor: 1.5,
        ),
        throwsArgumentError,
      );
    });
  });
}
