import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:image_editor/ai/inference/mask_to_alpha.dart';

void main() {
  group('blendMaskIntoRgba — validation', () {
    test('rejects zero mask dimensions', () {
      expect(
        () => blendMaskIntoRgba(
          mask: Float32List(0),
          maskWidth: 0,
          maskHeight: 2,
          sourceRgba: Uint8List(16),
          srcWidth: 2,
          srcHeight: 2,
        ),
        throwsArgumentError,
      );
    });

    test('rejects mismatched mask length', () {
      expect(
        () => blendMaskIntoRgba(
          mask: Float32List(3),
          maskWidth: 2,
          maskHeight: 2,
          sourceRgba: Uint8List(16),
          srcWidth: 2,
          srcHeight: 2,
        ),
        throwsArgumentError,
      );
    });

    test('rejects mismatched rgba length', () {
      expect(
        () => blendMaskIntoRgba(
          mask: Float32List(4),
          maskWidth: 2,
          maskHeight: 2,
          sourceRgba: Uint8List(8),
          srcWidth: 2,
          srcHeight: 2,
        ),
        throwsArgumentError,
      );
    });
  });

  group('blendMaskIntoRgba — values', () {
    test('same-size mask replaces alpha with scaled mask values', () {
      final rgba = Uint8List.fromList([
        255, 0, 0, 200, // alpha 200
        0, 255, 0, 100, // alpha 100
        0, 0, 255, 50,
        255, 255, 255, 0,
      ]);
      final mask = Float32List.fromList([1.0, 0.5, 0.0, 1.0]);
      final out = blendMaskIntoRgba(
        mask: mask,
        maskWidth: 2,
        maskHeight: 2,
        sourceRgba: rgba,
        srcWidth: 2,
        srcHeight: 2,
      );
      // R/G/B preserved, alpha replaced.
      expect(out[0], 255); // R
      expect(out[1], 0); // G
      expect(out[2], 0); // B
      expect(out[3], 255); // A = 1.0*255 = 255
      expect(out[7], closeTo(128, 1)); // A = 0.5*255 ≈ 128
      expect(out[11], 0); // A = 0*255 = 0
      expect(out[15], 255); // A = 1.0*255 = 255
    });

    test('threshold > 0 binarizes the mask', () {
      final rgba = Uint8List.fromList([
        0, 0, 0, 0,
        0, 0, 0, 0,
        0, 0, 0, 0,
        0, 0, 0, 0,
      ]);
      final mask = Float32List.fromList([0.4, 0.6, 0.7, 0.2]);
      final out = blendMaskIntoRgba(
        mask: mask,
        maskWidth: 2,
        maskHeight: 2,
        sourceRgba: rgba,
        srcWidth: 2,
        srcHeight: 2,
        threshold: 0.5,
      );
      expect(out[3], 0); // 0.4 < 0.5 → 0
      expect(out[7], 255); // 0.6 > 0.5 → 255
      expect(out[11], 255); // 0.7 > 0.5 → 255
      expect(out[15], 0); // 0.2 < 0.5 → 0
    });

    test('input buffer is not mutated (returns a copy)', () {
      final rgba = Uint8List.fromList([1, 2, 3, 99]);
      final mask = Float32List.fromList([0.0]);
      final out = blendMaskIntoRgba(
        mask: mask,
        maskWidth: 1,
        maskHeight: 1,
        sourceRgba: rgba,
        srcWidth: 1,
        srcHeight: 1,
      );
      expect(out[3], 0);
      expect(rgba[3], 99, reason: 'caller-owned buffer untouched');
    });

    test('low-res mask upsamples bilinearly to high-res', () {
      // 2×2 mask → 4×4 source. Corners should be exact, middles interpolate.
      final rgba = Uint8List(4 * 4 * 4);
      final mask = Float32List.fromList([
        1.0, 0.0,
        0.0, 1.0,
      ]);
      final out = blendMaskIntoRgba(
        mask: mask,
        maskWidth: 2,
        maskHeight: 2,
        sourceRgba: rgba,
        srcWidth: 4,
        srcHeight: 4,
      );
      // Corners must land exactly on source corners:
      // (0,0) → 1.0 → 255
      expect(out[3], 255);
      // (3,0) → 0.0 → 0
      expect(out[(0 * 4 + 3) * 4 + 3], 0);
      // (0,3) → 0.0 → 0
      expect(out[(3 * 4 + 0) * 4 + 3], 0);
      // (3,3) → 1.0 → 255
      expect(out[(3 * 4 + 3) * 4 + 3], 255);
      // Center (1,1) or (2,2): bilinear average of all 4 corners = 0.5 → 128.
      expect(out[(1 * 4 + 1) * 4 + 3], inInclusiveRange(85, 170));
    });
  });
}
