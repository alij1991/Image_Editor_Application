import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:image_editor/ai/services/denoise/ai_denoise_service.dart';

/// Phase XVI.50 — pin the pure-Dart helpers in `AiDenoiseService`.
/// The full inference path needs a live ORT session and isn't
/// exercisable from unit tests; the pieces below cover the parts
/// that are testable without a model file:
///
///   1. Input-name matching tolerates the multiple naming
///      conventions DnCNN ONNX exports use (input / image /
///      pixel_values / sample).
///   2. CHW tensor flattening — both `[1, 3, H, W]` (with batch) and
///      `[3, H, W]` (no batch) shapes flatten correctly.
///   3. Residual subtraction — `clean = clamp(input − residual)` for
///      the residual-learning DnCNN variants.
///   4. CHW → RGBA conversion at identity size and on a downsample.
void main() {
  group('AiDenoiseService.pickInputName', () {
    test('exact match on "input" wins', () {
      final out = AiDenoiseService.pickInputName(['input']);
      expect(out, 'input');
    });

    test('"image" matches second when "input" missing', () {
      final out = AiDenoiseService.pickInputName(['image', 'mask']);
      expect(out, 'image');
    });

    test('suffix match tolerates namespace prefixes', () {
      final out = AiDenoiseService.pickInputName(['model.input']);
      expect(out, 'model.input');
    });

    test('falls back to first input when nothing matches', () {
      final out = AiDenoiseService.pickInputName(['weird_name']);
      expect(out, 'weird_name');
    });

    test('empty list returns null', () {
      final out = AiDenoiseService.pickInputName(const []);
      expect(out, isNull);
    });
  });

  group('AiDenoiseService.flattenChw', () {
    test('null input returns null', () {
      expect(AiDenoiseService.flattenChw(null), isNull);
    });

    test('empty list returns null', () {
      expect(AiDenoiseService.flattenChw(const <dynamic>[]), isNull);
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
      final out = AiDenoiseService.flattenChw(raw);
      expect(out, isNotNull);
      expect(out!.length, 12);
      // Channel 0
      expect(out[0], closeTo(0.1, 1e-6));
      expect(out[1], closeTo(0.2, 1e-6));
      expect(out[2], closeTo(0.3, 1e-6));
      expect(out[3], closeTo(0.4, 1e-6));
      // Channel 1
      expect(out[4], closeTo(0.5, 1e-6));
      expect(out[5], closeTo(0.6, 1e-6));
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
      final out = AiDenoiseService.flattenChw(raw);
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
      expect(AiDenoiseService.flattenChw(raw), isNull);
    });

    test('inconsistent row width returns null', () {
      final raw = [
        [
          [0.1, 0.2, 0.3],
          [0.4, 0.5], // shorter row
        ],
        [
          [0, 0, 0],
          [0, 0, 0],
        ],
        [
          [0, 0, 0],
          [0, 0, 0],
        ],
      ];
      expect(AiDenoiseService.flattenChw(raw), isNull);
    });
  });

  group('AiDenoiseService.subtractResidual', () {
    test('clean = input - residual, clamped to [0, 1]', () {
      // Float32List rounds inputs at storage time, so the arithmetic
      // here is at single-precision; tolerance loosens to 1e-6.
      final input = Float32List.fromList([0.5, 0.8, 0.3, 0.0]);
      final residual = Float32List.fromList([0.2, 0.1, 0.5, -0.5]);
      final out = AiDenoiseService.subtractResidual(
        input: input,
        residual: residual,
      );
      // 0.5 - 0.2 = 0.3
      expect(out[0], closeTo(0.3, 1e-6));
      // 0.8 - 0.1 = 0.7
      expect(out[1], closeTo(0.7, 1e-6));
      // 0.3 - 0.5 = -0.2 → clamped to 0
      expect(out[2], closeTo(0.0, 1e-6));
      // 0.0 - (-0.5) = 0.5
      expect(out[3], closeTo(0.5, 1e-6));
    });

    test('clamps over-1 results back to 1', () {
      final input = Float32List.fromList([0.9]);
      final residual = Float32List.fromList([-0.5]);
      final out = AiDenoiseService.subtractResidual(
        input: input,
        residual: residual,
      );
      // 0.9 - (-0.5) = 1.4 → clamped to 1.0
      expect(out[0], closeTo(1.0, 1e-6));
    });

    test('mismatched lengths throw ArgumentError', () {
      expect(
        () => AiDenoiseService.subtractResidual(
          input: Float32List(4),
          residual: Float32List(8),
        ),
        throwsArgumentError,
      );
    });
  });

  group('AiDenoiseService.chwToRgba', () {
    test('identity size produces a directly-packable RGBA', () {
      // 1 × 1 image × 3 channels: [R=0.5, G=0.25, B=1.0]
      final chw = Float32List.fromList([0.5, 0.25, 1.0]);
      final out = AiDenoiseService.chwToRgba(
        chw: chw,
        chwWidth: 1,
        chwHeight: 1,
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
      final out = AiDenoiseService.chwToRgba(
        chw: chw,
        chwWidth: 1,
        chwHeight: 1,
        dstWidth: 1,
        dstHeight: 1,
      );
      expect(out[0], 0);
      expect(out[1], 128);
      expect(out[2], 255);
    });

    test('upsample 2×2 → 4×4 produces values inside [0, 255]', () {
      final chw = Float32List(3 * 2 * 2);
      // R plane all 0.5, G plane all 0.25, B plane all 1.0.
      for (var i = 0; i < 4; i++) {
        chw[i] = 0.5;
        chw[4 + i] = 0.25;
        chw[8 + i] = 1.0;
      }
      final out = AiDenoiseService.chwToRgba(
        chw: chw,
        chwWidth: 2,
        chwHeight: 2,
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

  test('kDnCnnColorModelId is the manifest identifier', () {
    // Phase XVI.65 — renamed from `dncnn_color_int8`. The actual
    // exported file (via scripts/onnx_export/convert_dncnn_color.py)
    // is the deepinv DnCNN-20 variant at FP32, not the INT8
    // canonical-17 the original scaffold assumed.
    expect(kDnCnnColorModelId, 'dncnn_deepinv_color_fp32');
  });

  group('AiDenoiseService.computeTargetDims (XVI.82)', () {
    test('1024×768 source under 1024 cap → identity dims (the field case)',
        () {
      // The same field case that drove the XVI.80 sharpen fix:
      // pre-XVI.82 the denoise service forced 1024×1024 SQUARE,
      // bilinear-stretching 768 → 1024 (resampling blur that
      // competed with the actual denoise pass for visible detail).
      final (w, h) = AiDenoiseService.computeTargetDims(
        srcWidth: 1024,
        srcHeight: 768,
        maxInputDim: 1024,
      );
      expect(w, 1024);
      expect(h, 768);
    });

    test('preserves aspect ratio when the source exceeds the cap', () {
      final (w, h) = AiDenoiseService.computeTargetDims(
        srcWidth: 2048,
        srcHeight: 1536,
        maxInputDim: 1024,
      );
      expect(w, 1024);
      expect(h, 768);
    });

    test('portrait orientation: long edge clamps height not width', () {
      final (w, h) = AiDenoiseService.computeTargetDims(
        srcWidth: 1536,
        srcHeight: 2048,
        maxInputDim: 1024,
      );
      expect(w, 768);
      expect(h, 1024);
    });

    test('rounds down to nearest /8 (DnCNN stride constraint)', () {
      final (w, h) = AiDenoiseService.computeTargetDims(
        srcWidth: 1023,
        srcHeight: 769,
        maxInputDim: 1024,
      );
      expect(w, 1016);
      expect(h, 768);
    });

    test('zero / negative dims return safe 8×8 defaults', () {
      final (w0, h0) = AiDenoiseService.computeTargetDims(
        srcWidth: 0,
        srcHeight: 100,
        maxInputDim: 1024,
      );
      expect(w0, 8);
      expect(h0, 8);
    });

    test('1×1 degenerate input still satisfies /8 minimum', () {
      final (w, h) = AiDenoiseService.computeTargetDims(
        srcWidth: 1,
        srcHeight: 1,
        maxInputDim: 1024,
      );
      expect(w, 8);
      expect(h, 8);
    });
  });

  group('AiDenoiseService.chwToRgba — rectangular CHW (XVI.82)', () {
    test('4×2 chw resamples to 4×2 dst as identity', () {
      final chw = Float32List(3 * 8);
      for (var i = 0; i < 8; i++) {
        chw[i] = 0.5;
        chw[8 + i] = 0.25;
        chw[16 + i] = 1.0;
      }
      final out = AiDenoiseService.chwToRgba(
        chw: chw,
        chwWidth: 4,
        chwHeight: 2,
        dstWidth: 4,
        dstHeight: 2,
      );
      expect(out, hasLength(4 * 2 * 4));
      for (var p = 0; p < 8; p++) {
        expect(out[p * 4], 128);
        expect(out[p * 4 + 1], 64);
        expect(out[p * 4 + 2], 255);
        expect(out[p * 4 + 3], 255);
      }
    });
  });
}
