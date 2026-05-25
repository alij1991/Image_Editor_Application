import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:image_editor/ai/lab/metrics/ssim.dart';

void main() {
  group('computeSsim', () {
    test('identical buffers → SSIM ≈ 1', () {
      final buf = _gradient(width: 16, height: 16);
      expect(
        computeSsim(buf, buf, width: 16, height: 16),
        closeTo(1.0, 1e-6),
      );
    });

    test('uniform vs uniform → SSIM 1', () {
      final a = Uint8List.fromList(List.filled(64 * 4, 128));
      final b = Uint8List.fromList(List.filled(64 * 4, 128));
      expect(
        computeSsim(a, b, width: 8, height: 8),
        closeTo(1.0, 1e-6),
      );
    });

    test('uniform white vs uniform black → SSIM near 0', () {
      final a = Uint8List.fromList(List.filled(64 * 4, 255));
      final b = Uint8List.fromList(List.filled(64 * 4, 0));
      final s = computeSsim(a, b, width: 8, height: 8);
      // Both variances are 0 → numerator collapses to C1*C2,
      // denominator to (255² + C1)*(C2). Score is very small.
      expect(s, lessThan(0.05));
      expect(s, greaterThanOrEqualTo(0));
    });

    test('small perturbation → SSIM near 1', () {
      // 16x16 gradient with +1 luma everywhere = perceptually
      // identical, SSIM should be > 0.99.
      final a = _gradient(width: 16, height: 16);
      final b = Uint8List.fromList(a);
      for (var i = 0; i < b.length; i += 4) {
        b[i] = (b[i] + 1).clamp(0, 255).toInt();
        b[i + 1] = (b[i + 1] + 1).clamp(0, 255).toInt();
        b[i + 2] = (b[i + 2] + 1).clamp(0, 255).toInt();
      }
      final s = computeSsim(a, b, width: 16, height: 16);
      expect(s, greaterThan(0.99));
    });

    test('large structural change → SSIM substantially below 1', () {
      // Sharp image vs the same with strong gaussian-like blur =
      // checkerboard vs flat mean.
      final checker = Uint8List(16 * 16 * 4);
      final flat = Uint8List(16 * 16 * 4);
      for (var y = 0; y < 16; y++) {
        for (var x = 0; x < 16; x++) {
          final v = (x + y).isEven ? 0 : 255;
          final i = (y * 16 + x) * 4;
          checker[i] = v;
          checker[i + 1] = v;
          checker[i + 2] = v;
          checker[i + 3] = 255;
          flat[i] = 128;
          flat[i + 1] = 128;
          flat[i + 2] = 128;
          flat[i + 3] = 255;
        }
      }
      final s = computeSsim(checker, flat, width: 16, height: 16);
      expect(s, lessThan(0.2));
    });

    test('size mismatch throws', () {
      expect(
        () => computeSsim(
          Uint8List(64 * 4),
          Uint8List(32 * 4),
          width: 8,
          height: 8,
        ),
        throwsArgumentError,
      );
    });

    test('wrong stride throws', () {
      expect(
        () => computeSsim(
          Uint8List(10),
          Uint8List(10),
          width: 4,
          height: 4,
        ),
        throwsArgumentError,
      );
    });
  });
}

/// Build a 16-step horizontal RGBA luma gradient of the requested
/// dimensions for SSIM stability tests.
Uint8List _gradient({required int width, required int height}) {
  final out = Uint8List(width * height * 4);
  for (var y = 0; y < height; y++) {
    for (var x = 0; x < width; x++) {
      final v = (x * 255 / (width - 1)).round();
      final i = (y * width + x) * 4;
      out[i] = v;
      out[i + 1] = v;
      out[i + 2] = v;
      out[i + 3] = 255;
    }
  }
  return out;
}
