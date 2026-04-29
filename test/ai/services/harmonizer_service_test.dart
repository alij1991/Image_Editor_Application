import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:image_editor/ai/services/compose_on_bg/harmonizer_service.dart';

/// Phase XVI.54 — pin the pure-Dart helpers in `HarmonizerService`
/// and the `HarmonizerArgs` value class. The full inference path
/// requires a live ORT session (no model file in tests), so the
/// pieces below cover the parts that are testable without one:
///
///   1. Mask bilinear resize.
///   2. Filter-args tensor flattening — both `[1, 8]` and `[8]`
///      shapes drop in.
///   3. `HarmonizerArgs.fromList` round-trip + identity helpers.
///   4. Out-of-distribution clamping keeps wild outputs bounded.
void main() {
  group('HarmonizerService.bilinearResizeMask', () {
    test('identity resize preserves the source mask', () {
      final src = Float32List.fromList([0.0, 0.5, 1.0, 0.25]);
      final out = HarmonizerService.bilinearResizeMask(
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
      final out = HarmonizerService.bilinearResizeMask(
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

  group('HarmonizerService.flattenArgs', () {
    test('null and empty inputs return null', () {
      expect(HarmonizerService.flattenArgs(null), isNull);
      expect(HarmonizerService.flattenArgs(const <dynamic>[]), isNull);
    });

    test('flat [8] tensor flattens directly', () {
      final raw = [0.1, 0.2, 0.3, 0.4, 0.5, 0.6, 0.7, 0.8];
      final out = HarmonizerService.flattenArgs(raw);
      expect(out, isNotNull);
      expect(out!.length, 8);
      expect(out[0], closeTo(0.1, 1e-6));
      expect(out[7], closeTo(0.8, 1e-6));
    });

    test('[1, 8] tensor (with batch) drops the batch axis', () {
      final raw = [
        [0.1, 0.2, 0.3, 0.4, 0.5, 0.6, 0.7, 0.8]
      ];
      final out = HarmonizerService.flattenArgs(raw);
      expect(out, isNotNull);
      expect(out!.length, 8);
      expect(out[0], closeTo(0.1, 1e-6));
      expect(out[7], closeTo(0.8, 1e-6));
    });

    test('non-numeric value returns null', () {
      final raw = [
        [0.1, 'oops', 0.3]
      ];
      expect(HarmonizerService.flattenArgs(raw), isNull);
    });
  });

  group('HarmonizerArgs', () {
    test('fromList unpacks 8 elements in canonical order', () {
      final args = HarmonizerArgs.fromList(
        [0.1, 0.2, 0.3, 0.4, 0.5, 0.6, 0.7, 0.8],
      );
      expect(args.brightness, 0.1);
      expect(args.contrast, 0.2);
      expect(args.saturation, 0.3);
      expect(args.temperature, 0.4);
      expect(args.tint, 0.5);
      expect(args.sharpness, 0.6);
      expect(args.highlights, 0.7);
      expect(args.shadows, 0.8);
    });

    test('fromList rejects wrong-length input', () {
      expect(
        () => HarmonizerArgs.fromList([0.1, 0.2]),
        throwsArgumentError,
      );
      expect(
        () => HarmonizerArgs.fromList(List.filled(9, 0.0)),
        throwsArgumentError,
      );
    });

    test('identity is all-zero', () {
      const id = HarmonizerArgs.identity;
      expect(id.brightness, 0.0);
      expect(id.contrast, 0.0);
      expect(id.saturation, 0.0);
      expect(id.temperature, 0.0);
      expect(id.tint, 0.0);
      expect(id.sharpness, 0.0);
      expect(id.highlights, 0.0);
      expect(id.shadows, 0.0);
    });

    test('isApproximatelyIdentity true on zero, false on non-zero', () {
      expect(
        HarmonizerArgs.identity.isApproximatelyIdentity(),
        isTrue,
      );
      const offset = HarmonizerArgs(
        brightness: 0.5,
        contrast: 0,
        saturation: 0,
        temperature: 0,
        tint: 0,
        sharpness: 0,
        highlights: 0,
        shadows: 0,
      );
      expect(offset.isApproximatelyIdentity(), isFalse);
    });

    test('isApproximatelyIdentity respects custom epsilon', () {
      const tiny = HarmonizerArgs(
        brightness: 0.0005,
        contrast: 0,
        saturation: 0,
        temperature: 0,
        tint: 0,
        sharpness: 0,
        highlights: 0,
        shadows: 0,
      );
      // Default eps 1e-3 → tiny is identity.
      expect(tiny.isApproximatelyIdentity(), isTrue);
      // Tighter eps → tiny is NOT identity.
      expect(tiny.isApproximatelyIdentity(eps: 1e-4), isFalse);
    });

    test('clamped caps every component to ±clipMagnitude', () {
      const wild = HarmonizerArgs(
        brightness: 5.0,
        contrast: -7.0,
        saturation: 3.0,
        temperature: -2.5,
        tint: 1.5,
        sharpness: -0.5,
        highlights: 2.0,
        shadows: -1.0,
      );
      final clamped = wild.clamped();
      expect(clamped.brightness, 1.0);
      expect(clamped.contrast, -1.0);
      expect(clamped.saturation, 1.0);
      expect(clamped.temperature, -1.0);
      expect(clamped.tint, 1.0);
      expect(clamped.sharpness, -0.5); // unchanged (in range)
      expect(clamped.highlights, 1.0);
      expect(clamped.shadows, -1.0);
    });

    test('clamped honours custom clipMagnitude', () {
      const wild = HarmonizerArgs(
        brightness: 0.8,
        contrast: -0.3,
        saturation: 0.0,
        temperature: 0.0,
        tint: 0.0,
        sharpness: 0.0,
        highlights: 0.0,
        shadows: 0.0,
      );
      final clamped = wild.clamped(clipMagnitude: 0.5);
      expect(clamped.brightness, 0.5);
      expect(clamped.contrast, -0.3); // unchanged
    });
  });

  group('HarmonizerService constants', () {
    test('input/output sizes match Harmonizer architecture', () {
      // Network is trained at 256×256; non-square works (the
      // regressor head is global-pooled) but quality drops outside
      // the training distribution.
      expect(HarmonizerService.inputSize, 256);
      expect(HarmonizerService.numFilterArgs, 8);
    });

    test('ImageNet preprocessing constants match HF transformers', () {
      expect(HarmonizerService.imageNetMean, [0.485, 0.456, 0.406]);
      expect(HarmonizerService.imageNetStd, [0.229, 0.224, 0.225]);
    });

    test('kHarmonizerModelId matches the manifest entry', () {
      expect(kHarmonizerModelId, 'harmonizer_eccv_2022');
    });
  });
}
