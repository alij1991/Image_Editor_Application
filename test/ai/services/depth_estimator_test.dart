import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:image_editor/ai/services/depth/depth_estimator.dart';

/// Phase XVI.40 — pin the helpers in `DepthEstimator` that don't need
/// a live ORT session. The full inference path goes through
/// `OrtRuntime.load(...)` and is exercised end-to-end via the AI
/// coordinator integration tests.
///
/// The pure helpers covered here:
///   1. Input/output name matching — tolerates the multiple naming
///      conventions HuggingFace ONNX exports use (pixel_values vs
///      input vs image; predicted_depth vs depth vs output).
///   2. Min-max normalisation — converts raw inverse-depth scalars
///      to `[0, 1]` per-image; degenerate constant-input must not
///      divide by zero.
///   3. Depth → RGBA packing — every pixel writes the same value
///      into R/G/B (so the shader can read either channel) and
///      255 to alpha.
void main() {
  group('DepthEstimator.findInput name matching', () {
    test('exact match on "pixel_values" wins', () {
      final out = DepthEstimator.findInputForTest(
        ['pixel_values'],
        const ['pixel_values', 'image', 'input'],
      );
      expect(out, 'pixel_values');
    });

    test('suffix match tolerates namespace prefixes', () {
      final out = DepthEstimator.findInputForTest(
        ['model.image'],
        const ['pixel_values', 'image', 'input'],
      );
      expect(out, 'model.image');
    });

    test('falls back to first input when nothing matches', () {
      final out = DepthEstimator.findInputForTest(
        ['some_random_name'],
        const ['pixel_values', 'image', 'input'],
      );
      expect(out, 'some_random_name');
    });

    test('empty input list returns null', () {
      final out = DepthEstimator.findInputForTest(
        const [],
        const ['pixel_values'],
      );
      expect(out, isNull);
    });
  });

  group('DepthEstimator.findOutput name matching', () {
    test('matches "predicted_depth" first', () {
      final out = DepthEstimator.findOutputForTest(
        ['predicted_depth', 'something_else'],
        const ['predicted_depth', 'depth', 'output'],
      );
      expect(out, 'predicted_depth');
    });

    test('falls back to "depth" when predicted_depth is missing', () {
      final out = DepthEstimator.findOutputForTest(
        ['depth'],
        const ['predicted_depth', 'depth', 'output'],
      );
      expect(out, 'depth');
    });

    test('returns null when nothing matches (caller falls back to all)', () {
      final out = DepthEstimator.findOutputForTest(
        ['some_random_name'],
        const ['predicted_depth', 'depth', 'output'],
      );
      expect(out, isNull);
    });
  });

  group('DepthEstimator.minMaxNormalise', () {
    test('linear ramp normalises to [0, 1]', () {
      final src = Float32List.fromList(const [0.0, 0.5, 1.0, 2.0]);
      final out = DepthEstimator.minMaxNormaliseForTest(src);
      expect(out[0], closeTo(0.0, 1e-9));
      expect(out[1], closeTo(0.25, 1e-9));
      expect(out[2], closeTo(0.5, 1e-9));
      expect(out[3], closeTo(1.0, 1e-9));
    });

    test('negative range is shifted to [0, 1]', () {
      // Depth-Anything outputs unbounded relative inverse depth. Min
      // can be negative; the per-image normalise must still produce
      // [0, 1].
      final src = Float32List.fromList(const [-2.0, 0.0, 2.0]);
      final out = DepthEstimator.minMaxNormaliseForTest(src);
      expect(out[0], closeTo(0.0, 1e-9));
      expect(out[1], closeTo(0.5, 1e-9));
      expect(out[2], closeTo(1.0, 1e-9));
    });

    test('degenerate constant input returns uniform 0.5 (no NaN)', () {
      // A flat depth field would otherwise divide by zero. The helper
      // must return a deterministic 0.5 fallback so the lens blur
      // reads "everything is at focus" and effectively no-ops.
      final src = Float32List.fromList(List.filled(16, 0.42));
      final out = DepthEstimator.minMaxNormaliseForTest(src);
      expect(out, hasLength(16));
      for (final v in out) {
        expect(v, closeTo(0.5, 1e-9));
      }
    });

    test('empty input returns empty (no crash)', () {
      final out = DepthEstimator.minMaxNormaliseForTest(Float32List(0));
      expect(out, isEmpty);
    });
  });

  group('DepthEstimator.depthToRgba packing', () {
    test('every depth sample replicates into R, G, B and 255 alpha', () {
      final depth = Float32List.fromList(const [0.0, 0.5, 1.0, 0.25]);
      final out = DepthEstimator.depthToRgbaForTest(depth, 2, 2);
      expect(out, hasLength(2 * 2 * 4));

      // Pixel 0: depth=0 → (0, 0, 0, 255).
      expect(out[0], 0);
      expect(out[1], 0);
      expect(out[2], 0);
      expect(out[3], 255);

      // Pixel 1: depth=0.5 → (128, 128, 128, 255).
      expect(out[4], 128);
      expect(out[5], 128);
      expect(out[6], 128);
      expect(out[7], 255);

      // Pixel 2: depth=1.0 → (255, 255, 255, 255).
      expect(out[8], 255);
      expect(out[9], 255);
      expect(out[10], 255);
      expect(out[11], 255);

      // Pixel 3: depth=0.25 → (64, 64, 64, 255).
      expect(out[12], 64);
      expect(out[13], 64);
      expect(out[14], 64);
      expect(out[15], 255);
    });

    test('out-of-range values clamp to [0, 255] without overflow', () {
      // Defensive — the normalise step should already clamp, but if
      // a caller skipped it the packer must still stay valid.
      final depth = Float32List.fromList(const [-0.1, 1.1]);
      final out = DepthEstimator.depthToRgbaForTest(depth, 2, 1);
      expect(out[0], inInclusiveRange(0, 255));
      expect(out[4], inInclusiveRange(0, 255));
      expect(out[3], 255);
      expect(out[7], 255);
    });
  });

  test('kDepthAnythingV2SmallModelId is the manifest identifier', () {
    // Tests that the model id constant matches the manifest entry,
    // catching the typo class where the service reads one id and the
    // manifest declares another.
    expect(kDepthAnythingV2SmallModelId, 'depth_anything_v2_small_int8');
  });

  test('DepthEstimator.inputSize is multiple of 14 (patch size)', () {
    // Depth-Anything-V2 ViT uses 14×14 patches; any input edge must
    // be a multiple of 14 or the patch tokeniser will reject it. 518
    // = 37 × 14 is the published default.
    expect(DepthEstimator.inputSize % 14, 0);
    expect(DepthEstimator.inputSize, 518);
  });

  test('DepthEstimator preprocessing constants match ImageNet pipeline', () {
    // Depth-Anything-V2 was trained on the standard HuggingFace
    // image-processing pipeline; using different mean/std would
    // shift every input pixel by ~10% and ruin depth quality.
    expect(DepthEstimator.imageNetMean, [0.485, 0.456, 0.406]);
    expect(DepthEstimator.imageNetStd, [0.229, 0.224, 0.225]);
  });
}
