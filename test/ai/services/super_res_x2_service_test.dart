import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:image_editor/ai/services/super_res/super_res_strategy.dart';
import 'package:image_editor/ai/services/super_res/super_res_x2_service.dart';

/// Phase XVI.53 — pin the pure-Dart helpers in `SuperResX2Service`
/// and the strategy interface invariants. The full inference path
/// requires a live ORT session (no model file in tests), so the
/// pieces below cover the parts that are testable without one:
///
///   1. Input-name matching tolerates Real-ESRGAN ONNX naming
///      variants ('input' / 'image' / 'pixel_values' / 'lr').
///   2. Letterboxed CHW tensor build — black padding outside the
///      scaled source, bilinear sample inside.
///   3. CHW flattening tolerates `[3, H, W]` and `[1, 3, H, W]`.
///   4. CHW → RGBA crop after letterboxed inference recovers the
///      source aspect ratio at 2× scale.
///   5. SuperResStrategyKind labels + scaleFactor map correctly.
void main() {
  group('SuperResX2Service.pickInputName', () {
    test('exact match on "input" wins', () {
      final out = SuperResX2Service.pickInputName(['input']);
      expect(out, 'input');
    });

    test('"image" matches second when "input" missing', () {
      final out = SuperResX2Service.pickInputName(['image', 'mask']);
      expect(out, 'image');
    });

    test('"lr" (low-res) matches the Real-ESRGAN convention', () {
      // Some xinntao exports name the input 'lr' (low-resolution).
      final out = SuperResX2Service.pickInputName(['lr']);
      expect(out, 'lr');
    });

    test('falls back to first input when nothing matches', () {
      final out = SuperResX2Service.pickInputName(['weird_name']);
      expect(out, 'weird_name');
    });

    test('empty list returns null', () {
      final out = SuperResX2Service.pickInputName(const []);
      expect(out, isNull);
    });
  });

  group('SuperResX2Service.buildLetterboxedChw', () {
    test('square source produces no padding', () {
      // 4×4 RGBA source → 4×4 letterbox = no padding.
      final src = Uint8List(4 * 4 * 4);
      for (var i = 0; i < src.length; i += 4) {
        src[i] = 100;
        src[i + 1] = 150;
        src[i + 2] = 200;
        src[i + 3] = 255;
      }
      final out = SuperResX2Service.buildLetterboxedChw(
        rgba: src,
        srcWidth: 4,
        srcHeight: 4,
        dstSize: 4,
      );
      expect(out, hasLength(3 * 4 * 4));
      // Centre pixel R channel should be 100/255.
      const hw = 16;
      final centreR = out[1 * 4 + 1]; // pixel (1, 1) plane R
      expect(centreR, closeTo(100 / 255, 1e-2));
      // Centre pixel G channel.
      final centreG = out[hw + 1 * 4 + 1];
      expect(centreG, closeTo(150 / 255, 1e-2));
      // Centre pixel B channel.
      final centreB = out[2 * hw + 1 * 4 + 1];
      expect(centreB, closeTo(200 / 255, 1e-2));
    });

    test('wide source letterboxes vertically', () {
      // 4×2 source → letterboxed in 4×4 with top + bottom padding.
      final src = Uint8List(4 * 2 * 4);
      for (var i = 0; i < src.length; i += 4) {
        src[i] = 200;
        src[i + 3] = 255;
      }
      final out = SuperResX2Service.buildLetterboxedChw(
        rgba: src,
        srcWidth: 4,
        srcHeight: 2,
        dstSize: 4,
      );
      // The source occupies rows 1-2 (centred); rows 0 and 3 are
      // black padding. Probe the top-left pixel R channel.
      final topLeftR = out[0 * 4 + 0];
      expect(topLeftR, 0.0); // padding
      // Centre pixel (around row 1) should be ~200/255.
      final midR = out[1 * 4 + 1];
      expect(midR, closeTo(200 / 255, 1e-2));
    });
  });

  group('SuperResX2Service.flattenChw', () {
    test('null and empty inputs return null', () {
      expect(SuperResX2Service.flattenChw(null), isNull);
      expect(SuperResX2Service.flattenChw(const <dynamic>[]), isNull);
    });

    test('[3, H, W] tensor flattens row-major per channel', () {
      final raw = [
        [
          [0.1, 0.2],
          [0.3, 0.4],
        ],
        [
          [0.5, 0.6],
          [0.7, 0.8],
        ],
        [
          [0.9, 1.0],
          [0.0, 0.0],
        ],
      ];
      final out = SuperResX2Service.flattenChw(raw);
      expect(out, isNotNull);
      expect(out!.length, 12);
      expect(out[0], closeTo(0.1, 1e-6));
      expect(out[8], closeTo(0.9, 1e-6));
    });

    test('[1, 3, H, W] tensor (with batch) flattens correctly', () {
      final raw = [
        [
          [
            [0.1, 0.2]
          ],
          [
            [0.3, 0.4]
          ],
          [
            [0.5, 0.6]
          ],
        ]
      ];
      final out = SuperResX2Service.flattenChw(raw);
      expect(out, isNotNull);
      expect(out!.length, 6);
      expect(out[0], closeTo(0.1, 1e-6));
    });

    test('non-3-channel returns null', () {
      final raw = [
        [
          [0.1]
        ],
        [
          [0.2]
        ],
        [
          [0.3]
        ],
        [
          [0.4]
        ], // 4 channels — invalid
      ];
      expect(SuperResX2Service.flattenChw(raw), isNull);
    });
  });

  group('SuperResX2Service.chwToRgbaCropped', () {
    test('full-size crop returns every pixel scaled to 0..255', () {
      // 2×2 CHW with all values 0.5 → output should be all 128.
      final chw = Float32List(3 * 2 * 2);
      for (var i = 0; i < chw.length; i++) {
        chw[i] = 0.5;
      }
      final out = SuperResX2Service.chwToRgbaCropped(
        chw: chw,
        chwSize: 2,
        cropX: 0,
        cropY: 0,
        cropW: 2,
        cropH: 2,
      );
      expect(out, hasLength(2 * 2 * 4));
      for (var p = 0; p < 4; p++) {
        final i = p * 4;
        expect(out[i], 128); // R
        expect(out[i + 1], 128); // G
        expect(out[i + 2], 128); // B
        expect(out[i + 3], 255); // alpha
      }
    });

    test('clamps out-of-range floats to [0, 255]', () {
      final chw = Float32List(3 * 1 * 1);
      chw[0] = -0.5; // R underflow
      chw[1] = 0.5; // G in range
      chw[2] = 1.5; // B overflow
      final out = SuperResX2Service.chwToRgbaCropped(
        chw: chw,
        chwSize: 1,
        cropX: 0,
        cropY: 0,
        cropW: 1,
        cropH: 1,
      );
      expect(out[0], 0); // R clamped to 0
      expect(out[1], 128); // G ≈ 0.5 * 255
      expect(out[2], 255); // B clamped to 255
      expect(out[3], 255); // alpha
    });

    test('sub-region crop excludes padding rows', () {
      // 4×4 CHW where rows 0 and 3 are red-only, rows 1-2 are green.
      final chw = Float32List(3 * 4 * 4);
      // R plane
      for (var y = 0; y < 4; y++) {
        for (var x = 0; x < 4; x++) {
          final i = y * 4 + x;
          chw[i] = (y == 0 || y == 3) ? 1.0 : 0.0;
          chw[16 + i] = (y == 0 || y == 3) ? 0.0 : 1.0; // G
        }
      }
      // Crop the middle 4×2 rectangle (rows 1-2). Should be all-green.
      final out = SuperResX2Service.chwToRgbaCropped(
        chw: chw,
        chwSize: 4,
        cropX: 0,
        cropY: 1,
        cropW: 4,
        cropH: 2,
      );
      expect(out, hasLength(4 * 2 * 4));
      for (var p = 0; p < 8; p++) {
        final i = p * 4;
        expect(out[i], 0); // R
        expect(out[i + 1], 255); // G
        expect(out[i + 3], 255); // alpha
      }
    });
  });

  group('SuperResStrategyKind labels and modelIds', () {
    test('every kind has a non-empty label', () {
      for (final k in SuperResStrategyKind.values) {
        expect(k.label, isNotEmpty, reason: 'missing label for ${k.name}');
      }
    });

    test('every kind has a non-empty description', () {
      for (final k in SuperResStrategyKind.values) {
        expect(k.description, isNotEmpty,
            reason: 'missing description for ${k.name}');
      }
    });

    test('x2 → real_esrgan_x2_fp16, x4 → real_esrgan_x4', () {
      expect(SuperResStrategyKind.x2.modelId, 'real_esrgan_x2_fp16');
      expect(SuperResStrategyKind.x4.modelId, 'real_esrgan_x4');
    });

    test('scaleFactor matches the kind name', () {
      expect(SuperResStrategyKind.x2.scaleFactor, 2);
      expect(SuperResStrategyKind.x4.scaleFactor, 4);
    });

    test('values are exactly {x2, x4}', () {
      expect(
        SuperResStrategyKind.values.map((k) => k.name).toList(),
        equals(['x2', 'x4']),
        reason: 'reordering breaks the picker; appending is fine',
      );
    });
  });

  group('SuperResException carries the strategy kind', () {
    test('kind propagates via constructor', () {
      const e = SuperResException(
        'oops',
        kind: SuperResStrategyKind.x2,
      );
      expect(e.kind, SuperResStrategyKind.x2);
      expect(e.message, 'oops');
      expect(e.toString(), contains('x2'));
    });

    test('kind null preserves pre-XVI.53 toString shape', () {
      const e = SuperResException('plain', cause: 'underlying');
      expect(e.kind, isNull);
      expect(e.toString(), contains('plain'));
      expect(e.toString(), contains('underlying'));
    });
  });

  test('kRealEsrganX2ModelId matches the manifest entry', () {
    expect(kRealEsrganX2ModelId, 'real_esrgan_x2_fp16');
    expect(kRealEsrganX2ModelId, SuperResStrategyKind.x2.modelId);
  });
}
