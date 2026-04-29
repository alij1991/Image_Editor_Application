import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:image_editor/ai/services/sharpen/ai_sharpen_service.dart';

/// Phase XVI.55 — pin the pure-Dart helpers in `AiSharpenService`.
/// The full inference path needs a live ORT session and isn't
/// exercisable from unit tests; the pieces below cover the parts
/// that are testable without a model file:
///
///   1. Input-name matching tolerates the multiple naming
///      conventions NAFNet / restoration-net ONNX exports use
///      (input / image / pixel_values / sample / lq).
///   2. CHW tensor flattening — both `[1, 3, H, W]` (with batch) and
///      `[3, H, W]` (no batch) shapes flatten correctly.
///   3. CHW → RGBA conversion at identity size and on a downsample,
///      with clamping.
///   4. kAiSharpenModelId matches the manifest entry.
///
/// Note: there is intentionally NO `subtractResidual` test here.
/// NAFNet emits the clean image directly — adding a residual flag
/// would invite a subtle double-subtract bug for a network family
/// that doesn't need it.
void main() {
  group('AiSharpenService.pickInputName', () {
    test('exact match on "input" wins', () {
      final out = AiSharpenService.pickInputName(['input']);
      expect(out, 'input');
    });

    test('"image" matches second when "input" missing', () {
      final out = AiSharpenService.pickInputName(['image', 'mask']);
      expect(out, 'image');
    });

    test('"lq" matches the low-quality input convention', () {
      // Some restoration ONNX exports name the input 'lq' (low
      // quality, the input the network must clean up).
      final out = AiSharpenService.pickInputName(['lq']);
      expect(out, 'lq');
    });

    test('suffix match tolerates namespace prefixes', () {
      final out = AiSharpenService.pickInputName(['model.input']);
      expect(out, 'model.input');
    });

    test('falls back to first input when nothing matches', () {
      final out = AiSharpenService.pickInputName(['weird_name']);
      expect(out, 'weird_name');
    });

    test('empty list returns null', () {
      final out = AiSharpenService.pickInputName(const []);
      expect(out, isNull);
    });
  });

  group('AiSharpenService.flattenChw', () {
    test('null input returns null', () {
      expect(AiSharpenService.flattenChw(null), isNull);
    });

    test('empty list returns null', () {
      expect(AiSharpenService.flattenChw(const <dynamic>[]), isNull);
    });

    test('[3, H, W] tensor flattens row-major per channel', () {
      // 3 × 2 × 2 — a 2×2 image with 3 channels.
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
      final out = AiSharpenService.flattenChw(raw);
      expect(out, isNotNull);
      expect(out!.length, 12);
      // Channel 0
      expect(out[0], closeTo(0.1, 1e-6));
      expect(out[3], closeTo(0.4, 1e-6));
      // Channel 1
      expect(out[4], closeTo(0.5, 1e-6));
      // Channel 2
      expect(out[8], closeTo(0.9, 1e-6));
    });

    test('[1, 3, H, W] tensor (with batch) flattens correctly', () {
      final raw = [
        [
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
        ]
      ];
      final out = AiSharpenService.flattenChw(raw);
      expect(out, isNotNull);
      expect(out!.length, 12);
      expect(out[0], closeTo(0.1, 1e-6));
      expect(out[8], closeTo(0.9, 1e-6));
    });

    test('non-3-channel tensor returns null', () {
      // [4, H, W] — wrong channel count.
      final raw = [
        [
          [0.1, 0.2]
        ],
        [
          [0.3, 0.4]
        ],
        [
          [0.5, 0.6]
        ],
        [
          [0.7, 0.8]
        ],
      ];
      expect(AiSharpenService.flattenChw(raw), isNull);
    });

    test('non-numeric value returns null', () {
      final raw = [
        [
          ['oops', 0.2]
        ],
        [
          [0.3, 0.4]
        ],
        [
          [0.5, 0.6]
        ],
      ];
      expect(AiSharpenService.flattenChw(raw), isNull);
    });
  });

  group('AiSharpenService.chwToRgba', () {
    test('identity size produces a directly-packable RGBA', () {
      // 1 × 1 image × 3 channels: [R=0.5, G=0.25, B=1.0]
      final chw = Float32List.fromList([0.5, 0.25, 1.0]);
      final out = AiSharpenService.chwToRgba(
        chw: chw,
        chwSize: 1,
        dstWidth: 1,
        dstHeight: 1,
      );
      expect(out, hasLength(4));
      // Bilinear interpolation degenerates to nearest at chwSize=1.
      expect(out[0], 128); // 0.5 * 255 = 127.5 → 128
      expect(out[1], 64); // 0.25 * 255 = 63.75 → 64
      expect(out[2], 255); // 1.0 * 255 = 255
      expect(out[3], 255); // alpha
    });

    test('clamps out-of-range floats to [0, 255]', () {
      final chw = Float32List.fromList([-0.5, 0.5, 1.5]);
      final out = AiSharpenService.chwToRgba(
        chw: chw,
        chwSize: 1,
        dstWidth: 1,
        dstHeight: 1,
      );
      expect(out[0], 0); // R clamped to 0
      expect(out[1], 128); // G ≈ 0.5 * 255
      expect(out[2], 255); // B clamped to 255
      expect(out[3], 255); // alpha
    });

    test('upsample 2×2 → 4×4 produces values inside [0, 255]', () {
      final chw = Float32List(3 * 2 * 2);
      // R plane all 0.5, G plane all 0.25, B plane all 1.0.
      for (var i = 0; i < 4; i++) {
        chw[i] = 0.5;
        chw[4 + i] = 0.25;
        chw[8 + i] = 1.0;
      }
      final out = AiSharpenService.chwToRgba(
        chw: chw,
        chwSize: 2,
        dstWidth: 4,
        dstHeight: 4,
      );
      expect(out, hasLength(4 * 4 * 4));
      // Every pixel should be (≈128, ≈64, 255, 255).
      for (var p = 0; p < 16; p++) {
        final i = p * 4;
        expect(out[i], inInclusiveRange(120, 135));
        expect(out[i + 1], inInclusiveRange(60, 70));
        expect(out[i + 2], 255);
        expect(out[i + 3], 255);
      }
    });
  });

  group('AiSharpenException', () {
    test('toString exposes message and cause', () {
      const e = AiSharpenException('oops', cause: 'underlying');
      final s = e.toString();
      expect(s, contains('oops'));
      expect(s, contains('underlying'));
    });

    test('toString without cause is concise', () {
      const e = AiSharpenException('oops');
      expect(e.toString(), 'AiSharpenException: oops');
    });
  });

  test('kAiSharpenModelId is the manifest identifier', () {
    // Phase XVI.64 — renamed from nafnet_32_deblur_fp16. The
    // publicly available NAFNet ONNX is OpenCV's 2025-05 FP32
    // export; no community FP16 variant exists.
    expect(kAiSharpenModelId, 'nafnet_deblur_2025may_fp32');
  });
}
