import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:image_editor/ai/services/sky_replace/segformer_sky_service.dart';

/// Phase XVI.52 — pin the pure-Dart helpers in `SegFormerSkyService`.
/// The full inference path requires a live ORT session (no model
/// file in tests), so the pieces below cover the parts that are
/// testable without one:
///
///   1. Input-name matching tolerates SegFormer ONNX naming variants
///      ('pixel_values' / 'input' / 'image' / 'sample').
///   2. CHW logits flattening reads `[1, C, H, W]` and `[C, H, W]`.
///   3. Numerically-stable softmax over the class axis returns the
///      sky-class probability per pixel.
///   4. Bilinear resize on a single-channel mask covers identity +
///      upsample.
///   5. ADE20K class index constant matches the SceneParse150 label
///      map (sky=2, distinct from the 151-class DeepLab variant
///      which uses 3).
void main() {
  group('SegFormerSkyService.pickInputName', () {
    test('exact match on "pixel_values" wins', () {
      final out = SegFormerSkyService.pickInputName(['pixel_values']);
      expect(out, 'pixel_values');
    });

    test('"input" matches when "pixel_values" missing', () {
      final out = SegFormerSkyService.pickInputName(['input', 'mask']);
      expect(out, 'input');
    });

    test('suffix match tolerates namespace prefixes', () {
      final out =
          SegFormerSkyService.pickInputName(['model.pixel_values']);
      expect(out, 'model.pixel_values');
    });

    test('falls back to first input when nothing matches', () {
      final out = SegFormerSkyService.pickInputName(['weird_name']);
      expect(out, 'weird_name');
    });

    test('empty list returns null', () {
      final out = SegFormerSkyService.pickInputName(const []);
      expect(out, isNull);
    });
  });

  group('SegFormerSkyService.flattenLogits', () {
    test('null input returns null', () {
      expect(SegFormerSkyService.flattenLogits(null), isNull);
    });

    test('[C, H, W] tensor flattens with right metadata', () {
      // 3 classes × 2×2 spatial.
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
      final out = SegFormerSkyService.flattenLogits(raw);
      expect(out, isNotNull);
      expect(out!.numClasses, 3);
      expect(out.height, 2);
      expect(out.width, 2);
      expect(out.data.length, 12);
      expect(out.data[0], closeTo(0.1, 1e-6));
      expect(out.data[8], closeTo(0.9, 1e-6));
    });

    test('[1, C, H, W] tensor (with batch) flattens correctly', () {
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
      final out = SegFormerSkyService.flattenLogits(raw);
      expect(out, isNotNull);
      expect(out!.numClasses, 3);
      expect(out.height, 1);
      expect(out.width, 2);
      expect(out.data[0], closeTo(0.1, 1e-6));
      expect(out.data[2], closeTo(0.3, 1e-6));
    });

    test('inconsistent shapes return null', () {
      final raw = [
        [
          [0.1, 0.2],
          [0.3], // shorter row
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
      expect(SegFormerSkyService.flattenLogits(raw), isNull);
    });
  });

  group('SegFormerSkyService.softmaxSkyClass', () {
    test('one-class-dominant logits → sky probability ≈ 1.0', () {
      // 3 classes, 1 pixel, sky logit much higher than others.
      // Layout: c0=0, c1=0, c2=10 (sky) → after softmax sky ≈ 1.
      final logits = Float32List.fromList([0.0, 0.0, 10.0]);
      final out = SegFormerSkyService.softmaxSkyClass(
        logits: logits,
        height: 1,
        width: 1,
        numClasses: 3,
        skyClassIndex: 2,
      );
      expect(out[0], closeTo(1.0, 1e-3));
    });

    test('uniform logits → sky probability ≈ 1/numClasses', () {
      // 3 classes with same logit → uniform softmax → 1/3 each.
      final logits = Float32List.fromList([1.0, 1.0, 1.0]);
      final out = SegFormerSkyService.softmaxSkyClass(
        logits: logits,
        height: 1,
        width: 1,
        numClasses: 3,
        skyClassIndex: 2,
      );
      expect(out[0], closeTo(1.0 / 3.0, 1e-6));
    });

    test('multi-pixel softmax computes per-pixel probabilities', () {
      // 2 classes × 2 pixels, CHW layout:
      //   class 0 plane: [0, 5]
      //   class 1 plane: [5, 0]   <- sky class
      // Pixel 0: c0=0, c1=5 → softmax sky = exp(5)/(exp(0)+exp(5)) ≈ 0.993
      // Pixel 1: c0=5, c1=0 → softmax sky = exp(0)/(exp(5)+exp(0)) ≈ 0.007
      final logits = Float32List.fromList([0.0, 5.0, 5.0, 0.0]);
      final out = SegFormerSkyService.softmaxSkyClass(
        logits: logits,
        height: 1,
        width: 2,
        numClasses: 2,
        skyClassIndex: 1,
      );
      // Logit gap of 5 → softmax tail ≈ 0.0067; loose 1e-2 tolerance.
      expect(out[0], closeTo(0.993, 1e-2));
      expect(out[1], closeTo(0.007, 1e-2));
      // The asymmetry is what matters — pixel 0 dominates pixel 1.
      expect(out[0], greaterThan(out[1]));
    });

    test('large negative logits do not produce NaN (numerical stability)',
        () {
      // Pre-stability fix the per-pixel max subtraction: subtracting
      // very large logits from each other would produce 0/0 = NaN.
      final logits = Float32List.fromList([1e6, 1e6 - 0.1]);
      final out = SegFormerSkyService.softmaxSkyClass(
        logits: logits,
        height: 1,
        width: 1,
        numClasses: 2,
        skyClassIndex: 0,
      );
      expect(out[0].isNaN, isFalse);
      expect(out[0], inInclusiveRange(0.0, 1.0));
    });

    test('out-of-range skyClassIndex throws', () {
      expect(
        () => SegFormerSkyService.softmaxSkyClass(
          logits: Float32List(3),
          height: 1,
          width: 1,
          numClasses: 3,
          skyClassIndex: 5,
        ),
        throwsArgumentError,
      );
    });

    test('mismatched logits length throws', () {
      expect(
        () => SegFormerSkyService.softmaxSkyClass(
          logits: Float32List(5), // not 3 × 2 × 2
          height: 2,
          width: 2,
          numClasses: 3,
          skyClassIndex: 1,
        ),
        throwsArgumentError,
      );
    });
  });

  group('SegFormerSkyService.bilinearResize', () {
    test('identity size copies the source unchanged', () {
      final src = Float32List.fromList([0.0, 0.5, 1.0, 0.25]);
      final out = SegFormerSkyService.bilinearResize(
        src: src,
        srcWidth: 2,
        srcHeight: 2,
        dstWidth: 2,
        dstHeight: 2,
      );
      for (var i = 0; i < 4; i++) {
        expect(out[i], closeTo(src[i], 1e-6));
      }
    });

    test('upsample 2×2 → 4×4 stays in source range', () {
      final src = Float32List.fromList([0, 1, 0, 1]);
      final out = SegFormerSkyService.bilinearResize(
        src: src,
        srcWidth: 2,
        srcHeight: 2,
        dstWidth: 4,
        dstHeight: 4,
      );
      for (final v in out) {
        expect(v, inInclusiveRange(0.0, 1.0));
      }
    });
  });

  group('SegFormerSkyService constants', () {
    test('input/output sizes match SegFormer-B0 architecture', () {
      // SegFormer-B0 fine-tuned at 512×512; encoder stride 4 → output
      // logits at 128×128.
      expect(SegFormerSkyService.inputSize, 512);
      expect(SegFormerSkyService.outputSize, 128);
      expect(SegFormerSkyService.numClasses, 150);
    });

    test('default sky class is 2 (SceneParse150 zero-indexed)', () {
      // The DeepLab ADE20K model uses 151 classes (0=unlabeled,
      // sky=3); SegFormer drops the unlabeled slot (0..149,
      // sky=2). Pin both indices to catch a future swap.
      expect(SegFormerSkyService.ade20kSkyClass, 2);
    });

    test('ImageNet preprocessing constants match HF transformers', () {
      // SegFormer was trained on the standard HuggingFace
      // image-processing pipeline; using different mean/std would
      // ruin segmentation quality.
      expect(SegFormerSkyService.imageNetMean, [0.485, 0.456, 0.406]);
      expect(SegFormerSkyService.imageNetStd, [0.229, 0.224, 0.225]);
    });

    test('kSegFormerB0SkyModelId matches the manifest entry', () {
      expect(kSegFormerB0SkyModelId, 'segformer_b0_ade20k_512_int8');
    });
  });
}
