import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:image_editor/ai/inference/image_tensor.dart';

void main() {
  group('ImageTensor.fromRgba — validation', () {
    test('rejects non-positive source dimensions', () {
      expect(
        () => ImageTensor.fromRgba(
          rgba: Uint8List(16),
          srcWidth: 0,
          srcHeight: 2,
          dstWidth: 2,
          dstHeight: 2,
        ),
        throwsArgumentError,
      );
    });

    test('rejects non-positive destination dimensions', () {
      expect(
        () => ImageTensor.fromRgba(
          rgba: Uint8List(16),
          srcWidth: 2,
          srcHeight: 2,
          dstWidth: 0,
          dstHeight: 2,
        ),
        throwsArgumentError,
      );
    });

    test('rejects rgba length mismatch', () {
      expect(
        () => ImageTensor.fromRgba(
          rgba: Uint8List(8),
          srcWidth: 2,
          srcHeight: 2,
          dstWidth: 2,
          dstHeight: 2,
        ),
        throwsArgumentError,
        reason: '2x2x4 = 16 but we passed 8',
      );
    });

    test('rejects mean / std that do not have length 3', () {
      expect(
        () => ImageTensor.fromRgba(
          rgba: Uint8List.fromList(List<int>.filled(16, 0)),
          srcWidth: 2,
          srcHeight: 2,
          dstWidth: 2,
          dstHeight: 2,
          mean: const [0.5, 0.5],
        ),
        throwsArgumentError,
      );
      expect(
        () => ImageTensor.fromRgba(
          rgba: Uint8List.fromList(List<int>.filled(16, 0)),
          srcWidth: 2,
          srcHeight: 2,
          dstWidth: 2,
          dstHeight: 2,
          std: const [1.0, 1.0, 1.0, 1.0],
        ),
        throwsArgumentError,
      );
    });
  });

  group('ImageTensor.fromRgba — values', () {
    test('identity resize preserves pixel values scaled to [0,1]', () {
      // 2×2 image: red, green, blue, white.
      final rgba = Uint8List.fromList([
        255, 0, 0, 255, // (0,0) red
        0, 255, 0, 255, // (1,0) green
        0, 0, 255, 255, // (0,1) blue
        255, 255, 255, 255, // (1,1) white
      ]);
      final t = ImageTensor.fromRgba(
        rgba: rgba,
        srcWidth: 2,
        srcHeight: 2,
        dstWidth: 2,
        dstHeight: 2,
      );
      expect(t.shape, [1, 3, 2, 2]);
      expect(t.data.length, 12);
      // Channel planes: [R0,R1,R2,R3, G0,G1,G2,G3, B0,B1,B2,B3].
      // R plane: 1, 0, 0, 1
      expect(t.data[0], closeTo(1.0, 1e-6));
      expect(t.data[1], closeTo(0.0, 1e-6));
      expect(t.data[2], closeTo(0.0, 1e-6));
      expect(t.data[3], closeTo(1.0, 1e-6));
      // G plane: 0, 1, 0, 1
      expect(t.data[4], closeTo(0.0, 1e-6));
      expect(t.data[5], closeTo(1.0, 1e-6));
      expect(t.data[6], closeTo(0.0, 1e-6));
      expect(t.data[7], closeTo(1.0, 1e-6));
      // B plane: 0, 0, 1, 1
      expect(t.data[8], closeTo(0.0, 1e-6));
      expect(t.data[9], closeTo(0.0, 1e-6));
      expect(t.data[10], closeTo(1.0, 1e-6));
      expect(t.data[11], closeTo(1.0, 1e-6));
    });

    test('MODNet normalization maps [0,255] to [-1,1]', () {
      // 1×1 grey image.
      final rgba = Uint8List.fromList([127, 127, 127, 255]);
      final t = ImageTensor.fromRgba(
        rgba: rgba,
        srcWidth: 1,
        srcHeight: 1,
        dstWidth: 1,
        dstHeight: 1,
        mean: const [0.5, 0.5, 0.5],
        std: const [0.5, 0.5, 0.5],
      );
      // 127/255 ≈ 0.498, (0.498 - 0.5)/0.5 ≈ -0.00392
      const expected = -0.00392;
      expect(t.data[0], closeTo(expected, 1e-4));
      expect(t.data[1], closeTo(expected, 1e-4));
      expect(t.data[2], closeTo(expected, 1e-4));

      // Pure black → -1.0, pure white → +1.0.
      final black = ImageTensor.fromRgba(
        rgba: Uint8List.fromList([0, 0, 0, 255]),
        srcWidth: 1,
        srcHeight: 1,
        dstWidth: 1,
        dstHeight: 1,
        mean: const [0.5, 0.5, 0.5],
        std: const [0.5, 0.5, 0.5],
      );
      expect(black.data[0], closeTo(-1.0, 1e-6));
      final white = ImageTensor.fromRgba(
        rgba: Uint8List.fromList([255, 255, 255, 255]),
        srcWidth: 1,
        srcHeight: 1,
        dstWidth: 1,
        dstHeight: 1,
        mean: const [0.5, 0.5, 0.5],
        std: const [0.5, 0.5, 0.5],
      );
      expect(white.data[0], closeTo(1.0, 1e-6));
    });

    test('CHW layout: plane stride equals H*W', () {
      final rgba = Uint8List.fromList([
        10, 20, 30, 255,
        40, 50, 60, 255,
        70, 80, 90, 255,
        100, 110, 120, 255,
      ]);
      final t = ImageTensor.fromRgba(
        rgba: rgba,
        srcWidth: 2,
        srcHeight: 2,
        dstWidth: 2,
        dstHeight: 2,
      );
      // Plane R starts at 0, G at 4, B at 8.
      expect(t.data[0], closeTo(10 / 255, 1e-5)); // R at (0,0)
      expect(t.data[4], closeTo(20 / 255, 1e-5)); // G at (0,0)
      expect(t.data[8], closeTo(30 / 255, 1e-5)); // B at (0,0)
    });

    test('asNested shape matches [1][3][H][W]', () {
      final rgba = Uint8List.fromList([
        10, 20, 30, 255,
        40, 50, 60, 255,
        70, 80, 90, 255,
        100, 110, 120, 255,
      ]);
      final t = ImageTensor.fromRgba(
        rgba: rgba,
        srcWidth: 2,
        srcHeight: 2,
        dstWidth: 2,
        dstHeight: 2,
      );
      final nested = t.asNested();
      expect(nested.length, 1, reason: 'batch');
      expect(nested[0].length, 3, reason: 'channels');
      expect(nested[0][0].length, 2, reason: 'height');
      expect(nested[0][0][0].length, 2, reason: 'width');
      expect(nested[0][0][0][0], closeTo(10 / 255, 1e-5));
      expect(nested[0][1][1][1], closeTo(110 / 255, 1e-5));
    });
  });
}
