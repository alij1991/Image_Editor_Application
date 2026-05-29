import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:image_editor/ai/inference/image_tensor.dart';
import 'package:image_editor/ai/inference/wet_dry_blend.dart';
import 'package:image_editor/ai/services/bg_removal/image_io.dart';
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

  group('AiDenoiseService decode resolution (XVI.103)', () {
    test('default decode dimension is native quality, not the 1024 cap',
        () {
      // The bug: the service used to decode at the BgRemovalImageIo
      // default (1024), producing a 768×1024 cutout that the editor
      // upscaled onto the 1920+ preview → blur. The fix decodes at
      // native quality (4096) so the output keeps full detail.
      expect(AiDenoiseService.kDefaultDecodeDimension,
          BgRemovalImageIo.nativeQualityDecodeDimension);
      expect(
        AiDenoiseService.kDefaultDecodeDimension,
        greaterThan(BgRemovalImageIo.maxDecodeDimension),
        reason: 'must decode above the old 1024 default to avoid the '
            'upscale-blur regression',
      );
    });
  });

  group('XVI.103 resolution-preservation pipeline (pure helpers)', () {
    // Proves the denoise resolution flow end-to-end WITHOUT a model:
    // a native-res source letterboxes down to the model's fixed
    // 1024, the (simulated) model output crops to the content rect,
    // then chwToRgba upscales BACK to the full source dims and the
    // wet/dry blend runs at full resolution. Asserts the final
    // buffer is full-resolution — the dimension the old code lost.
    test('native-res source survives the letterbox→crop→upscale→blend '
        'round-trip at full resolution', () {
      // Simulate a 1536×2048 native decode (what a 4096-cap decode of
      // a 3:4 phone photo yields). Bigger than the 1024 model square.
      const fullW = 1536;
      const fullH = 2048;
      final source = Uint8List(fullW * fullH * 4);
      for (var i = 0; i < source.length; i += 4) {
        source[i] = 200;
        source[i + 1] = 150;
        source[i + 2] = 100;
        source[i + 3] = 255;
      }

      // 1. Letterbox the native-res source into the model's 1024².
      final t = ImageTensor.letterboxFromRgba(
        rgba: source,
        srcWidth: fullW,
        srcHeight: fullH,
        paddedDim: 1024,
      );
      // The 2048-tall source scales by 1024/2048 = 0.5 → 768×1024.
      expect(t.contentWidth, 768);
      expect(t.contentHeight, 1024);

      // 2. Simulate the model output == cropped content (identity
      //    "denoise"). Crop the content region back out.
      final contentChw = ImageTensor.cropLetterboxedChw(
        paddedChw: t.data,
        paddedDim: 1024,
        contentX: t.contentX,
        contentY: t.contentY,
        contentWidth: t.contentWidth,
        contentHeight: t.contentHeight,
      );

      // 3. Upscale the model output back to the FULL source dims.
      final rgbaModel = AiDenoiseService.chwToRgba(
        chw: contentChw,
        chwWidth: t.contentWidth,
        chwHeight: t.contentHeight,
        dstWidth: fullW,
        dstHeight: fullH,
      );
      // The fix: the model output is resized to full resolution, not
      // left at the 1024 model size.
      expect(rgbaModel.length, fullW * fullH * 4);

      // 4. Blend at full resolution against the full-res source.
      final blended = blendWetDry(
        source: source,
        processed: rgbaModel,
        strength: kDefaultDenoiseStrength,
      );
      // The whole point: the output buffer is full-resolution. The
      // pre-XVI.103 bug would have produced a 768×1024 buffer here.
      expect(blended.length, fullW * fullH * 4);
    });
  });

  group('ImageTensor.letterboxFromRgba — XVI.87 denoise preprocessing', () {
    // Note: these test the LIBRARY function the denoise service now
    // calls. The actual XVI.82 native-resolution helpers were removed
    // when the bundled DnCNN export turned out to require fixed
    // 1024×1024 input (the manifest comment claiming "any /8" was
    // wrong for this specific export). See XVI.87 commit notes.
    test('1024×768 source letterboxes inside 1024² with content centered',
        () {
      final rgba = Uint8List(1024 * 768 * 4);
      // Mark all pixels gray so any spurious crop is visible.
      for (var i = 0; i < rgba.length; i += 4) {
        rgba[i] = 128;
        rgba[i + 1] = 128;
        rgba[i + 2] = 128;
        rgba[i + 3] = 255;
      }
      final t = ImageTensor.letterboxFromRgba(
        rgba: rgba,
        srcWidth: 1024,
        srcHeight: 768,
        paddedDim: 1024,
      );
      expect(t.shape, [1, 3, 1024, 1024]);
      // Long edge fills the padded square; short edge gets pad.
      expect(t.contentWidth, 1024);
      expect(t.contentHeight, 768);
      expect(t.contentX, 0);
      expect(t.contentY, 128); // (1024 - 768) / 2
    });

    test('portrait source letterboxes with horizontal padding', () {
      final rgba = Uint8List(768 * 1024 * 4);
      final t = ImageTensor.letterboxFromRgba(
        rgba: rgba,
        srcWidth: 768,
        srcHeight: 1024,
        paddedDim: 1024,
      );
      expect(t.shape, [1, 3, 1024, 1024]);
      expect(t.contentWidth, 768);
      expect(t.contentHeight, 1024);
      expect(t.contentX, 128);
      expect(t.contentY, 0);
    });

    test('square source = identity (no padding)', () {
      final rgba = Uint8List(512 * 512 * 4);
      final t = ImageTensor.letterboxFromRgba(
        rgba: rgba,
        srcWidth: 512,
        srcHeight: 512,
        paddedDim: 1024,
      );
      // Content fills the whole padded canvas — scale = 1024/512 = 2,
      // so 512² source becomes 1024² content (no padding).
      expect(t.contentWidth, 1024);
      expect(t.contentHeight, 1024);
      expect(t.contentX, 0);
      expect(t.contentY, 0);
    });

    test('cropLetterboxedChw extracts content region precisely', () {
      // Build a 4×4 padded canvas with a 2×2 content rect at (1,1).
      // Fill content with R=0.5/G=0.25/B=1.0, pad with zeros.
      final padded = Float32List(3 * 16);
      for (var y = 1; y <= 2; y++) {
        for (var x = 1; x <= 2; x++) {
          final idx = y * 4 + x;
          padded[idx] = 0.5;
          padded[16 + idx] = 0.25;
          padded[32 + idx] = 1.0;
        }
      }
      final content = ImageTensor.cropLetterboxedChw(
        paddedChw: padded,
        paddedDim: 4,
        contentX: 1,
        contentY: 1,
        contentWidth: 2,
        contentHeight: 2,
      );
      // content should be [0.5, 0.5, 0.5, 0.5, 0.25, 0.25, 0.25, 0.25, 1.0, 1.0, 1.0, 1.0]
      expect(content, hasLength(3 * 4));
      for (var i = 0; i < 4; i++) {
        expect(content[i], 0.5); // R plane
        expect(content[4 + i], 0.25); // G plane
        expect(content[8 + i], 1.0); // B plane
      }
    });

    test(
        'rejects mismatched RGBA length / zero dims (defensive '
        'validation)', () {
      expect(
        () => ImageTensor.letterboxFromRgba(
          rgba: Uint8List(10),
          srcWidth: 100,
          srcHeight: 100,
          paddedDim: 256,
        ),
        throwsArgumentError,
      );
      expect(
        () => ImageTensor.letterboxFromRgba(
          rgba: Uint8List(100),
          srcWidth: 0,
          srcHeight: 5,
          paddedDim: 256,
        ),
        throwsArgumentError,
      );
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
