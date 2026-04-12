import 'package:flutter_test/flutter_test.dart';

import 'package:image_editor/ai/services/bg_removal/rmbg_bg_removal.dart';

void main() {
  group('RmbgBgRemoval._flattenMask (via flattenMaskForTest)', () {
    test('null input → null', () {
      expect(RmbgBgRemoval.flattenMaskForTest(null), isNull);
    });

    test('empty list → null', () {
      expect(RmbgBgRemoval.flattenMaskForTest(const <dynamic>[]), isNull);
    });

    test('flat [H][W] matrix of doubles flattens row-major', () {
      final raw = [
        [0.1, 0.2, 0.3],
        [0.4, 0.5, 0.6],
      ];
      final out = RmbgBgRemoval.flattenMaskForTest(raw);
      expect(out, isNotNull);
      expect(out!.length, 6);
      expect(out[0], closeTo(0.1, 1e-6));
      expect(out[1], closeTo(0.2, 1e-6));
      expect(out[2], closeTo(0.3, 1e-6));
      expect(out[3], closeTo(0.4, 1e-6));
      expect(out[4], closeTo(0.5, 1e-6));
      expect(out[5], closeTo(0.6, 1e-6));
    });

    test('RMBG-style [1][1][H][W] tensor walks past batch + channel', () {
      // Simulate `OrtValue.value` return shape for a [1, 1, 2, 3] tensor.
      final raw = [
        [
          [
            [0.0, 0.5, 1.0],
            [1.0, 0.5, 0.0],
          ],
        ],
      ];
      final out = RmbgBgRemoval.flattenMaskForTest(raw);
      expect(out, isNotNull);
      expect(out!.length, 6);
      expect(out[0], 0.0);
      expect(out[2], 1.0);
      expect(out[3], 1.0);
      expect(out[5], 0.0);
    });

    test('inconsistent row width → null', () {
      final raw = [
        [0.1, 0.2, 0.3],
        [0.4, 0.5], // shorter row
      ];
      expect(RmbgBgRemoval.flattenMaskForTest(raw), isNull);
    });

    test('non-numeric element → null', () {
      final raw = [
        [0.1, 'oops', 0.3],
        [0.4, 0.5, 0.6],
      ];
      expect(RmbgBgRemoval.flattenMaskForTest(raw), isNull);
    });

    test('int values are coerced to double', () {
      final raw = [
        [0, 1],
        [1, 0],
      ];
      final out = RmbgBgRemoval.flattenMaskForTest(raw);
      expect(out, isNotNull);
      expect(out!.toList(), [0.0, 1.0, 1.0, 0.0]);
    });
  });
}
