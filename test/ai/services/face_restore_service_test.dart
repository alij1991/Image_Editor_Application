import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:image_editor/ai/services/face_restore/face_restore_service.dart';

/// Phase XVI.56 — pin the pure-Dart helpers in `FaceRestoreService`.
/// The full inference path needs a live ORT session + face detector
/// and isn't exercisable from unit tests. The pieces below cover the
/// parts that are testable without a model:
///
///   1. Square bbox expansion — padding, clamping, off-image bboxes.
///   2. Bilinear crop-to-square — colour fidelity at identity, plus
///      sub-region selection.
///   3. `[-1, 1]` → `[0, 1]` unscale, with clamping outside the
///      expected range.
///   4. `pasteCropBack` mutates only the crop region.
///   5. Input-name matching tolerates the common naming variants.
///   6. CHW flattening tolerates `[3, H, W]` and `[1, 3, H, W]`.
///   7. SquareCrop value-class equality + kFaceRestoreModelId.
void main() {
  group('FaceRestoreService.expandSquareBbox', () {
    test('square bbox in centre of image expands by padding factor', () {
      // 100×100 bbox centred in a 1000×1000 image, 30% padding →
      // expand to 160×160 centred at (500, 500) → origin (420, 420).
      final box = FaceRestoreService.expandSquareBbox(
        left: 450,
        top: 450,
        width: 100,
        height: 100,
        imageWidth: 1000,
        imageHeight: 1000,
        padding: 0.30,
      );
      expect(box.size, 160);
      // Origin should be roughly (420, 420) — `floor` of (420.0, 420.0).
      expect(box.x, 420);
      expect(box.y, 420);
    });

    test('rectangle bbox uses the longer edge for the square', () {
      // 80×120 portrait bbox → square edge driven by 120 → 120 * 1.6
      // = 192 (rounded via `ceil`).
      final box = FaceRestoreService.expandSquareBbox(
        left: 460,
        top: 440,
        width: 80,
        height: 120,
        imageWidth: 1000,
        imageHeight: 1000,
        padding: 0.30,
      );
      expect(box.size, 192);
    });

    test('clamps origin so crop stays inside the image', () {
      // bbox at the top-left corner — padding would push origin
      // negative, so clamping pulls it back to (0, 0).
      final box = FaceRestoreService.expandSquareBbox(
        left: 0,
        top: 0,
        width: 100,
        height: 100,
        imageWidth: 1000,
        imageHeight: 1000,
        padding: 0.30,
      );
      expect(box.x, 0);
      expect(box.y, 0);
      expect(box.size, 160);
    });

    test('clamps far corner so crop stays inside the image', () {
      // bbox at the bottom-right corner — padding would push the far
      // corner past (1000, 1000), so origin shifts up-and-left.
      final box = FaceRestoreService.expandSquareBbox(
        left: 900,
        top: 900,
        width: 100,
        height: 100,
        imageWidth: 1000,
        imageHeight: 1000,
        padding: 0.30,
      );
      // box.size = 160; origin = 1000 - 160 = 840.
      expect(box.x, 840);
      expect(box.y, 840);
      expect(box.size, 160);
    });

    test('huge bbox clamps size to the smaller image edge', () {
      // bbox 600×600 with 30% pad → 960. Image is 800×1200, so the
      // square clamps to 800.
      final box = FaceRestoreService.expandSquareBbox(
        left: 100,
        top: 200,
        width: 600,
        height: 600,
        imageWidth: 800,
        imageHeight: 1200,
        padding: 0.30,
      );
      expect(box.size, 800);
    });

    test('zero padding still keeps the bbox square', () {
      // 80×120 → square edge = 120 (no padding).
      final box = FaceRestoreService.expandSquareBbox(
        left: 460,
        top: 440,
        width: 80,
        height: 120,
        imageWidth: 1000,
        imageHeight: 1000,
        padding: 0.0,
      );
      expect(box.size, 120);
    });
  });

  group('FaceRestoreService.bilinearCropToSquare', () {
    test('identity crop at full image returns every pixel', () {
      // 4×4 RGB checkerboard.
      final src = Uint8List(4 * 4 * 4);
      for (var i = 0; i < src.length; i += 4) {
        src[i] = 100; // R
        src[i + 1] = 150; // G
        src[i + 2] = 200; // B
        src[i + 3] = 255; // A
      }
      final out = FaceRestoreService.bilinearCropToSquare(
        rgba: src,
        srcWidth: 4,
        srcHeight: 4,
        cropX: 0,
        cropY: 0,
        cropSize: 4,
        dstSize: 4,
      );
      expect(out, hasLength(4 * 4 * 4));
      // Every pixel should preserve (100, 150, 200, 255).
      for (var i = 0; i < out.length; i += 4) {
        expect(out[i], 100);
        expect(out[i + 1], 150);
        expect(out[i + 2], 200);
        expect(out[i + 3], 255);
      }
    });

    test('crop sub-region picks up the right colours', () {
      // 4×4 image: top-left quadrant is RED, rest is BLACK.
      final src = Uint8List(4 * 4 * 4);
      for (var y = 0; y < 4; y++) {
        for (var x = 0; x < 4; x++) {
          final i = (y * 4 + x) * 4;
          if (y < 2 && x < 2) {
            src[i] = 255; // R
          }
          src[i + 3] = 255;
        }
      }
      // Crop the red quadrant only → output should be all-red.
      final out = FaceRestoreService.bilinearCropToSquare(
        rgba: src,
        srcWidth: 4,
        srcHeight: 4,
        cropX: 0,
        cropY: 0,
        cropSize: 2,
        dstSize: 2,
      );
      expect(out, hasLength(2 * 2 * 4));
      for (var i = 0; i < out.length; i += 4) {
        expect(out[i], 255);
        expect(out[i + 1], 0);
        expect(out[i + 2], 0);
        expect(out[i + 3], 255);
      }
    });

    test('zero crop size returns an all-zero buffer', () {
      final src = Uint8List(4 * 4 * 4)..fillRange(0, 4 * 4 * 4, 200);
      final out = FaceRestoreService.bilinearCropToSquare(
        rgba: src,
        srcWidth: 4,
        srcHeight: 4,
        cropX: 0,
        cropY: 0,
        cropSize: 0,
        dstSize: 2,
      );
      expect(out, hasLength(2 * 2 * 4));
      for (final b in out) {
        expect(b, 0);
      }
    });
  });

  group('FaceRestoreService.unscaleSignedChw', () {
    test('-1 / 0 / 1 map to 0 / 0.5 / 1', () {
      final signed = Float32List.fromList([-1.0, 0.0, 1.0]);
      final out = FaceRestoreService.unscaleSignedChw(signed);
      expect(out[0], closeTo(0.0, 1e-6));
      expect(out[1], closeTo(0.5, 1e-6));
      expect(out[2], closeTo(1.0, 1e-6));
    });

    test('out-of-range inputs clamp to [0, 1]', () {
      final signed = Float32List.fromList([-2.0, 2.0]);
      final out = FaceRestoreService.unscaleSignedChw(signed);
      expect(out[0], 0.0);
      expect(out[1], 1.0);
    });

    test('preserves length', () {
      final signed = Float32List(12);
      expect(FaceRestoreService.unscaleSignedChw(signed).length, 12);
    });
  });

  group('FaceRestoreService.pasteCropBack', () {
    test('writes only inside the crop rectangle', () {
      // Start with all-zero patched buffer. CHW with R plane all 1.0
      // (255), other planes 0.
      final patched = Uint8List(4 * 4 * 4);
      for (var i = 0; i < patched.length; i += 4) {
        patched[i + 3] = 255;
      }
      final chw = Float32List(3 * 2 * 2);
      for (var i = 0; i < 4; i++) {
        chw[i] = 1.0; // R = 1
      }
      // Paste a 2×2 crop at (1, 1) → only pixels (1,1)/(1,2)/(2,1)/(2,2).
      FaceRestoreService.pasteCropBack(
        patched: patched,
        patchedWidth: 4,
        patchedHeight: 4,
        chw: chw,
        chwSize: 2,
        cropX: 1,
        cropY: 1,
        cropSize: 2,
      );
      // Pixel (0, 0) must remain (0, 0, 0, 255).
      expect(patched[0], 0);
      expect(patched[1], 0);
      expect(patched[2], 0);
      // Pixel (1, 1) must be ~(255, 0, 0, 255).
      const p11 = (1 * 4 + 1) * 4;
      expect(patched[p11], 255);
      expect(patched[p11 + 1], 0);
      // Pixel (3, 3) must remain (0, 0, 0, 255) — outside the crop.
      const p33 = (3 * 4 + 3) * 4;
      expect(patched[p33], 0);
    });

    test('out-of-bounds crop is clipped, not extrapolated', () {
      final patched = Uint8List(2 * 2 * 4);
      for (var i = 0; i < patched.length; i += 4) {
        patched[i + 3] = 255;
      }
      final chw = Float32List(3 * 4 * 4);
      for (var i = 0; i < chw.length; i++) {
        chw[i] = 1.0;
      }
      // Try to paste a 4×4 crop starting at (0, 0) into a 2×2 patched
      // buffer — only the first 2×2 should be written.
      FaceRestoreService.pasteCropBack(
        patched: patched,
        patchedWidth: 2,
        patchedHeight: 2,
        chw: chw,
        chwSize: 4,
        cropX: 0,
        cropY: 0,
        cropSize: 4,
      );
      // All four written pixels should be (255, 255, 255, _).
      for (var i = 0; i < 4; i++) {
        expect(patched[i * 4], 255);
      }
    });
  });

  group('FaceRestoreService.pickInputName', () {
    test('exact match on "input" wins', () {
      expect(FaceRestoreService.pickInputName(['input']), 'input');
    });
    test('"image" matches second when "input" missing', () {
      expect(
        FaceRestoreService.pickInputName(['image', 'mask']),
        'image',
      );
    });
    test('falls back to first when nothing matches', () {
      expect(FaceRestoreService.pickInputName(['weird']), 'weird');
    });
    test('empty list returns null', () {
      expect(FaceRestoreService.pickInputName(const []), isNull);
    });
  });

  group('FaceRestoreService.flattenChw', () {
    test('null and empty inputs return null', () {
      expect(FaceRestoreService.flattenChw(null), isNull);
      expect(FaceRestoreService.flattenChw(const <dynamic>[]), isNull);
    });

    test('[3, H, W] tensor flattens row-major per channel', () {
      final raw = [
        [
          [0.1, 0.2],
        ],
        [
          [0.3, 0.4],
        ],
        [
          [0.5, 0.6],
        ],
      ];
      final out = FaceRestoreService.flattenChw(raw);
      expect(out, isNotNull);
      expect(out!.length, 6);
      expect(out[0], closeTo(0.1, 1e-6));
      expect(out[2], closeTo(0.3, 1e-6));
      expect(out[4], closeTo(0.5, 1e-6));
    });

    test('[1, 3, H, W] tensor (with batch) flattens correctly', () {
      final raw = [
        [
          [
            [0.1]
          ],
          [
            [0.3]
          ],
          [
            [0.5]
          ],
        ]
      ];
      final out = FaceRestoreService.flattenChw(raw);
      expect(out, isNotNull);
      expect(out!.length, 3);
    });

    test('non-3-channel returns null', () {
      final raw = [
        [
          [0.1]
        ],
        [
          [0.2]
        ], // only 2 channels
      ];
      expect(FaceRestoreService.flattenChw(raw), isNull);
    });
  });

  group('SquareCrop value class', () {
    test('equality + hashCode pin x/y/size identity', () {
      const a = SquareCrop(x: 1, y: 2, size: 100);
      const b = SquareCrop(x: 1, y: 2, size: 100);
      const c = SquareCrop(x: 1, y: 2, size: 101);
      expect(a, b);
      expect(a == c, isFalse);
      expect(a.hashCode, b.hashCode);
    });

    test('toString includes all fields', () {
      const a = SquareCrop(x: 5, y: 10, size: 99);
      expect(a.toString(), contains('5'));
      expect(a.toString(), contains('10'));
      expect(a.toString(), contains('99'));
    });
  });

  test('kFaceRestoreModelId matches the manifest entry', () {
    expect(kFaceRestoreModelId, 'restoreformer_pp_fp16');
  });
}
