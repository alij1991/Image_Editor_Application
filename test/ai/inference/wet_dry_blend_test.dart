import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:image_editor/ai/inference/wet_dry_blend.dart';

void main() {
  group('blendWetDry', () {
    test('strength 0 returns the source verbatim', () {
      final src = Uint8List.fromList([10, 20, 30, 255]);
      final proc = Uint8List.fromList([200, 100, 50, 255]);
      expect(
        blendWetDry(source: src, processed: proc, strength: 0),
        [10, 20, 30, 255],
      );
    });

    test('strength 1 returns the processed verbatim', () {
      final src = Uint8List.fromList([10, 20, 30, 255]);
      final proc = Uint8List.fromList([200, 100, 50, 255]);
      expect(
        blendWetDry(source: src, processed: proc, strength: 1),
        [200, 100, 50, 255],
      );
    });

    test('strength 0.5 is the midpoint per channel', () {
      final src = Uint8List.fromList([100, 100, 100, 255]);
      final proc = Uint8List.fromList([200, 0, 50, 255]);
      // Midpoint: r=150, g=50, b=75. alpha carried from src.
      expect(
        blendWetDry(source: src, processed: proc, strength: 0.5),
        [150, 50, 75, 255],
      );
    });

    test('strength clamps to [0, 1]', () {
      final src = Uint8List.fromList([0, 0, 0, 255]);
      final proc = Uint8List.fromList([100, 100, 100, 255]);
      final lo =
          blendWetDry(source: src, processed: proc, strength: -0.5);
      final hi = blendWetDry(source: src, processed: proc, strength: 2);
      expect(lo, [0, 0, 0, 255]);
      expect(hi, [100, 100, 100, 255]);
    });

    test('alpha taken from source even when processed differs', () {
      final src = Uint8List.fromList([100, 100, 100, 200]);
      final proc = Uint8List.fromList([100, 100, 100, 50]);
      final out =
          blendWetDry(source: src, processed: proc, strength: 0.5);
      expect(out[3], 200,
          reason: 'alpha must come from source, not processed');
    });

    test('output is rounded, not truncated', () {
      // src=100, proc=101, strength=0.5 → midpoint 100.5 → rounds to
      // 101 (not 100).
      final src = Uint8List.fromList([100, 100, 100, 255]);
      final proc = Uint8List.fromList([101, 101, 101, 255]);
      final out =
          blendWetDry(source: src, processed: proc, strength: 0.5);
      expect(out[0], 101);
    });

    test('mismatched buffer sizes throws ArgumentError', () {
      expect(
        () => blendWetDry(
          source: Uint8List(4),
          processed: Uint8List(8),
          strength: 0.5,
        ),
        throwsArgumentError,
      );
    });

    test('non-RGBA-aligned length throws ArgumentError', () {
      expect(
        () => blendWetDry(
          source: Uint8List(7),
          processed: Uint8List(7),
          strength: 0.5,
        ),
        throwsArgumentError,
      );
    });

    test('empty buffers round-trip cleanly', () {
      expect(
        blendWetDry(
          source: Uint8List(0),
          processed: Uint8List(0),
          strength: 0.5,
        ),
        isEmpty,
      );
    });
  });

  group('strength constants', () {
    test('denoise default is below deblur default', () {
      // We expect denoise to be more conservative because aggressive
      // smoothing destroys face detail.
      expect(kDefaultDenoiseStrength,
          lessThan(kDefaultDeblurStrength));
    });

    test('both defaults are in (0, 1)', () {
      expect(kDefaultDenoiseStrength, greaterThan(0));
      expect(kDefaultDenoiseStrength, lessThan(1));
      expect(kDefaultDeblurStrength, greaterThan(0));
      expect(kDefaultDeblurStrength, lessThan(1));
    });
  });
}
