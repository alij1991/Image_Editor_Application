import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:image_editor/ai/inference/rgba_compositor.dart';

void main() {
  group('compositeOverlayRgba — validation', () {
    test('rejects non-positive dimensions', () {
      expect(
        () => compositeOverlayRgba(
          base: Uint8List(16),
          overlay: Uint8List(16),
          mask: Float32List(4),
          width: 0,
          height: 4,
        ),
        throwsArgumentError,
      );
    });

    test('rejects mismatched base length', () {
      expect(
        () => compositeOverlayRgba(
          base: Uint8List(8),
          overlay: Uint8List(16),
          mask: Float32List(4),
          width: 2,
          height: 2,
        ),
        throwsArgumentError,
      );
    });

    test('rejects mismatched overlay length', () {
      expect(
        () => compositeOverlayRgba(
          base: Uint8List(16),
          overlay: Uint8List(8),
          mask: Float32List(4),
          width: 2,
          height: 2,
        ),
        throwsArgumentError,
      );
    });

    test('rejects mismatched mask length', () {
      expect(
        () => compositeOverlayRgba(
          base: Uint8List(16),
          overlay: Uint8List(16),
          mask: Float32List(3),
          width: 2,
          height: 2,
        ),
        throwsArgumentError,
      );
    });
  });

  group('compositeOverlayRgba — values', () {
    test('mask=0 → output equals base', () {
      final base = Uint8List.fromList([10, 20, 30, 200]);
      final overlay = Uint8List.fromList([200, 100, 50, 99]);
      final mask = Float32List.fromList(const [0.0]);
      final out = compositeOverlayRgba(
        base: base,
        overlay: overlay,
        mask: mask,
        width: 1,
        height: 1,
      );
      expect(out[0], 10);
      expect(out[1], 20);
      expect(out[2], 30);
      // Alpha always sticks to base.
      expect(out[3], 200);
    });

    test('mask=1 → RGB equals overlay (alpha still from base)', () {
      final base = Uint8List.fromList([10, 20, 30, 200]);
      final overlay = Uint8List.fromList([200, 100, 50, 99]);
      final mask = Float32List.fromList(const [1.0]);
      final out = compositeOverlayRgba(
        base: base,
        overlay: overlay,
        mask: mask,
        width: 1,
        height: 1,
      );
      expect(out[0], 200);
      expect(out[1], 100);
      expect(out[2], 50);
      expect(out[3], 200);
    });

    test('mask=0.5 → linear interpolation', () {
      final base = Uint8List.fromList([0, 0, 0, 255]);
      final overlay = Uint8List.fromList([200, 100, 50, 99]);
      final mask = Float32List.fromList(const [0.5]);
      final out = compositeOverlayRgba(
        base: base,
        overlay: overlay,
        mask: mask,
        width: 1,
        height: 1,
      );
      expect(out[0], 100);
      expect(out[1], 50);
      expect(out[2], 25);
      expect(out[3], 255);
    });

    test('inputs are not mutated', () {
      final base = Uint8List.fromList([10, 20, 30, 255]);
      final overlay = Uint8List.fromList([200, 100, 50, 99]);
      final mask = Float32List.fromList(const [0.5]);
      final out = compositeOverlayRgba(
        base: base,
        overlay: overlay,
        mask: mask,
        width: 1,
        height: 1,
      );
      expect(base[0], 10);
      expect(overlay[0], 200);
      // Just to confirm we got something.
      expect(out[0], 105);
    });

    test('out-of-range mask values are clamped', () {
      final base = Uint8List.fromList([10, 20, 30, 255]);
      final overlay = Uint8List.fromList([200, 100, 50, 99]);
      final mask = Float32List.fromList(const [-0.5]); // → 0
      final out = compositeOverlayRgba(
        base: base,
        overlay: overlay,
        mask: mask,
        width: 1,
        height: 1,
      );
      expect(out[0], 10);
      expect(out[1], 20);
      expect(out[2], 30);

      final mask2 = Float32List.fromList(const [1.5]); // → 1
      final out2 = compositeOverlayRgba(
        base: base,
        overlay: overlay,
        mask: mask2,
        width: 1,
        height: 1,
      );
      expect(out2[0], 200);
      expect(out2[1], 100);
      expect(out2[2], 50);
    });
  });
}
