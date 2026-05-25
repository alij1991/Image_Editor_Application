import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:image_editor/ai/lab/metrics/psnr.dart';

void main() {
  group('computeMse', () {
    test('identical RGBA buffers → MSE 0', () {
      final a = Uint8List.fromList([10, 20, 30, 255, 40, 50, 60, 255]);
      final b = Uint8List.fromList([10, 20, 30, 255, 40, 50, 60, 255]);
      expect(computeMse(a, b, stride: 4), 0.0);
    });

    test('RGBA MSE ignores alpha channel', () {
      final a = Uint8List.fromList([0, 0, 0, 255, 0, 0, 0, 255]);
      final b = Uint8List.fromList([0, 0, 0, 0, 0, 0, 0, 0]);
      expect(computeMse(a, b, stride: 4), 0.0);
    });

    test('grayscale MSE matches manual calc', () {
      final a = Uint8List.fromList([0, 10, 20, 30]);
      final b = Uint8List.fromList([0, 0, 0, 0]);
      // MSE = (0+100+400+900)/4 = 350.
      expect(computeMse(a, b, stride: 1), 350.0);
    });

    test('mismatched lengths throws', () {
      expect(
        () => computeMse(Uint8List(4), Uint8List(8), stride: 1),
        throwsArgumentError,
      );
    });

    test('empty buffers → MSE 0', () {
      expect(computeMse(Uint8List(0), Uint8List(0), stride: 1), 0.0);
    });
  });

  group('computePsnr', () {
    test('identical → infinity', () {
      final buf = Uint8List.fromList(List.filled(16, 128));
      expect(computePsnr(buf, buf, stride: 1), double.infinity);
    });

    test('1-bit difference per pixel → ~48 dB', () {
      final a = Uint8List.fromList(List.filled(16, 100));
      final b = Uint8List.fromList(List.filled(16, 101));
      final psnr = computePsnr(a, b, stride: 1);
      expect(psnr, closeTo(48.13, 0.1));
    });

    test('zero vs max → 0 dB', () {
      final a = Uint8List.fromList(List.filled(16, 0));
      final b = Uint8List.fromList(List.filled(16, 255));
      final psnr = computePsnr(a, b, stride: 1);
      expect(psnr, closeTo(0, 0.1));
    });

    test('noise around 30 dB band sanity check', () {
      // sigma ≈ 8 corresponds to ~30 dB PSNR.
      final a = Uint8List.fromList(List.filled(1024, 128));
      final b = Uint8List(1024);
      // Deterministic pseudo-noise: alternating ±8.
      for (var i = 0; i < b.length; i++) {
        b[i] = 128 + (i.isEven ? 8 : -8);
      }
      final psnr = computePsnr(a, b, stride: 1);
      expect(psnr, closeTo(30.10, 0.5));
    });
  });
}
