import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:image_editor/ai/lab/metrics/laplacian_variance.dart';

void main() {
  group('rgbaToLuma', () {
    test('pure white → 255', () {
      final rgba = Uint8List.fromList([255, 255, 255, 255]);
      expect(rgbaToLuma(rgba), [255]);
    });

    test('pure black → 0', () {
      final rgba = Uint8List.fromList([0, 0, 0, 255]);
      expect(rgbaToLuma(rgba), [0]);
    });

    test('pure green dominates → ~182', () {
      // 0.7152 * 255 = 182.4
      final rgba = Uint8List.fromList([0, 255, 0, 255]);
      final luma = rgbaToLuma(rgba);
      expect(luma[0], closeTo(182, 2));
    });

    test('alpha is ignored', () {
      final a = rgbaToLuma(Uint8List.fromList([100, 100, 100, 0]));
      final b = rgbaToLuma(Uint8List.fromList([100, 100, 100, 255]));
      expect(a, b);
    });

    test('throws on non-multiple-of-4 length', () {
      expect(() => rgbaToLuma(Uint8List(3)), throwsArgumentError);
    });
  });

  group('computeLaplacianVariance', () {
    test('flat image → variance 0', () {
      final flat = Uint8List.fromList(List.filled(64, 128));
      expect(
        computeLaplacianVariance(flat, width: 8, height: 8),
        closeTo(0, 1e-9),
      );
    });

    test('checkerboard → high variance', () {
      // 8x8 checkerboard: maximally high frequencies.
      final checker = Uint8List(64);
      for (var y = 0; y < 8; y++) {
        for (var x = 0; x < 8; x++) {
          checker[y * 8 + x] = (x + y).isEven ? 0 : 255;
        }
      }
      final v = computeLaplacianVariance(checker, width: 8, height: 8);
      expect(v, greaterThan(100_000));
    });

    test('sharper image > blurrier image of the same content', () {
      // Sharp step edge in the centre vs blurred step edge.
      final sharp = Uint8List(64);
      final blur = Uint8List(64);
      for (var y = 0; y < 8; y++) {
        for (var x = 0; x < 8; x++) {
          sharp[y * 8 + x] = x < 4 ? 0 : 255;
          // Blurred = linear ramp at the boundary cells.
          if (x < 3) {
            blur[y * 8 + x] = 0;
          } else if (x > 4) {
            blur[y * 8 + x] = 255;
          } else {
            blur[y * 8 + x] = 128;
          }
        }
      }
      final vSharp = computeLaplacianVariance(sharp, width: 8, height: 8);
      final vBlur = computeLaplacianVariance(blur, width: 8, height: 8);
      expect(vSharp, greaterThan(vBlur));
    });

    test('returns 0 for sub-3x3 images', () {
      final tiny = Uint8List(4);
      expect(computeLaplacianVariance(tiny, width: 2, height: 2), 0);
    });

    test('throws on size mismatch', () {
      expect(
        () => computeLaplacianVariance(Uint8List(8), width: 4, height: 4),
        throwsArgumentError,
      );
    });
  });
}
