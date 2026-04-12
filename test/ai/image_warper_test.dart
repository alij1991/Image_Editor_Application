import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';

import 'package:image_editor/ai/inference/image_warper.dart';

/// Build a simple 4x4 RGBA test pattern where each pixel's R value
/// is its linear index (0..15) scaled to [0, 255]. G, B, A are
/// constant. This makes it easy to identify which source pixel
/// ended up where after a warp.
Uint8List _testPattern4x4() {
  final out = Uint8List(4 * 4 * 4);
  for (int y = 0; y < 4; y++) {
    for (int x = 0; x < 4; x++) {
      final idx = (y * 4 + x) * 4;
      out[idx] = ((y * 4 + x) * 17) % 256; // R
      out[idx + 1] = 100;
      out[idx + 2] = 50;
      out[idx + 3] = 255;
    }
  }
  return out;
}

void main() {
  group('ImageWarper.apply — validation', () {
    test('rejects non-positive dimensions', () {
      expect(
        () => ImageWarper.apply(
          source: Uint8List(16),
          width: 0,
          height: 2,
          anchors: const [],
        ),
        throwsArgumentError,
      );
    });

    test('rejects mismatched buffer length', () {
      expect(
        () => ImageWarper.apply(
          source: Uint8List(8),
          width: 2,
          height: 2,
          anchors: const [],
        ),
        throwsArgumentError,
      );
    });
  });

  group('ImageWarper.apply — identity cases', () {
    test('empty anchor list returns an exact copy (not same object)', () {
      final src = _testPattern4x4();
      final out = ImageWarper.apply(
        source: src,
        width: 4,
        height: 4,
        anchors: const [],
      );
      expect(out, orderedEquals(src));
      expect(identical(out, src), false);
    });

    test('anchor with zero displacement is identity', () {
      final src = _testPattern4x4();
      final out = ImageWarper.apply(
        source: src,
        width: 4,
        height: 4,
        anchors: const [
          WarpAnchor(
            source: ui.Offset(2, 2),
            target: ui.Offset(2, 2),
            radius: 3,
          ),
        ],
      );
      expect(out, orderedEquals(src));
    });

    test('zero-radius anchor is a no-op', () {
      final src = _testPattern4x4();
      final out = ImageWarper.apply(
        source: src,
        width: 4,
        height: 4,
        anchors: const [
          WarpAnchor(
            source: ui.Offset(1, 1),
            target: ui.Offset(3, 3),
            radius: 0,
          ),
        ],
      );
      expect(out, orderedEquals(src));
    });
  });

  group('ImageWarper.apply — displacement behavior', () {
    test('anchor at pixel center pulls that pixel toward the target', () {
      // 4x1 grayscale row. RGB: [0, 85, 170, 255]. Place an anchor
      // exactly on pixel index 1 (value 85) with target = pixel 3
      // (value 255) and a radius of 1.5. The center pixel's
      // displacement will be (target - source) = (+2, 0), so it
      // should inverse-sample at index -1 (clamped to 0), reading
      // the value 0.
      //
      // Actually: at a pixel ON the anchor source, the smoothstep
      // weight is 1, so dst_1 pulls from src at (1 - 2, 0) = (-1, 0)
      // clamp-extended to (0, 0) — the value 0.
      final src = Uint8List.fromList([
        0, 0, 0, 255,
        85, 85, 85, 255,
        170, 170, 170, 255,
        255, 255, 255, 255,
      ]);
      final out = ImageWarper.apply(
        source: src,
        width: 4,
        height: 1,
        anchors: const [
          WarpAnchor(
            source: ui.Offset(1, 0),
            target: ui.Offset(3, 0),
            radius: 1.5,
          ),
        ],
      );
      // Pixel 1 now reads from source x ≈ -1 → clamped to 0.
      expect(out[4], lessThan(85));
      // Pixel 3 (at distance 2 from anchor, outside radius 1.5)
      // is untouched.
      expect(out[12], 255);
    });

    test('alpha is preserved through the warp', () {
      final src = _testPattern4x4();
      // Use alpha 200 everywhere for a visible signal.
      for (int i = 3; i < src.length; i += 4) {
        src[i] = 200;
      }
      final out = ImageWarper.apply(
        source: src,
        width: 4,
        height: 4,
        anchors: const [
          WarpAnchor(
            source: ui.Offset(1, 1),
            target: ui.Offset(3, 3),
            radius: 3,
          ),
        ],
      );
      for (int i = 3; i < out.length; i += 4) {
        expect(out[i], 200,
            reason: 'alpha must survive warp at every pixel');
      }
    });

    test('input buffer is not mutated', () {
      final src = _testPattern4x4();
      final before = Uint8List.fromList(src);
      ImageWarper.apply(
        source: src,
        width: 4,
        height: 4,
        anchors: const [
          WarpAnchor(
            source: ui.Offset(2, 2),
            target: ui.Offset(0, 0),
            radius: 4,
          ),
        ],
      );
      expect(src, orderedEquals(before));
    });

    test('anchors outside the image produce a valid output', () {
      final src = _testPattern4x4();
      final out = ImageWarper.apply(
        source: src,
        width: 4,
        height: 4,
        anchors: const [
          WarpAnchor(
            source: ui.Offset(-10, -10),
            target: ui.Offset(-20, -20),
            radius: 2,
          ),
        ],
      );
      // Out-of-bounds anchor should not touch the image (its
      // iteration range is empty after clipping).
      expect(out, orderedEquals(src));
    });

    test('overlapping anchors average via normalized weights', () {
      // Two anchors pulling the same center pixel in opposite
      // directions with equal strength → the normalized
      // displacement should cancel to ~zero.
      final src = _testPattern4x4();
      final out = ImageWarper.apply(
        source: src,
        width: 4,
        height: 4,
        anchors: const [
          WarpAnchor(
            source: ui.Offset(1.5, 1.5),
            target: ui.Offset(3.5, 1.5),
            radius: 2,
          ),
          WarpAnchor(
            source: ui.Offset(1.5, 1.5),
            target: ui.Offset(-0.5, 1.5),
            radius: 2,
          ),
        ],
      );
      // Center pixel should be approximately identity. Check R
      // channel (easily distinguishable by position).
      const centerIdx = (1 * 4 + 1) * 4;
      final srcCenter = src[centerIdx];
      expect((out[centerIdx] - srcCenter).abs(), lessThanOrEqualTo(2),
          reason: 'opposite displacements should cancel');
    });
  });
}
