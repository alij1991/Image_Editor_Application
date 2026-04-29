import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:image_editor/ai/services/selfie_segmentation/hair_clothes_recolour_service.dart';
import 'package:image_editor/ai/services/selfie_segmentation/selfie_multiclass_service.dart';

/// Phase XVI.47 — pin the multiclass-output processing helpers and
/// the RecolourTarget value class. These are the pure-Dart pieces of
/// the "Selfie Multiclass for hair/clothes" upgrade; the live
/// inference path is exercised end-to-end via integration tests.
///
/// Helpers covered:
///   1. [SelfieMulticlassResult.argmax] — per-pixel winning class
///      from the flat 6-class score tensor.
///   2. [SelfieMulticlassResult.maskForClasses] — returns 1.0 for
///      pixels whose argmax is in the requested set, 0.0 otherwise.
///   3. [SelfieMulticlassResult.bilinearResize] — feathers the hard
///      argmax into a smooth 0..1 ramp during upsample.
///   4. [RecolourTarget] — pre-XVI.47 the recolour API took loose
///      `(classes, R, G, B)` argument groups; XVI.47 ships them as a
///      typed value class so the multi-target API is unambiguous.

/// Build a `[width × height × numClasses]` flat score tensor where
/// pixel `(x, y)` has a peak score at the requested class index.
Float32List _buildSingleClassScores({
  required int width,
  required int height,
  required int numClasses,
  required int classIndex,
}) {
  final out = Float32List(width * height * numClasses);
  for (var p = 0; p < width * height; p++) {
    final base = p * numClasses;
    out[base + classIndex] = 1.0;
  }
  return out;
}

/// Build a tensor where the LEFT half is class A and the RIGHT half
/// is class B. Lets us test masks that should select one half.
Float32List _buildSplitScores({
  required int width,
  required int height,
  required int numClasses,
  required int leftClass,
  required int rightClass,
}) {
  final out = Float32List(width * height * numClasses);
  for (var y = 0; y < height; y++) {
    for (var x = 0; x < width; x++) {
      final base = (y * width + x) * numClasses;
      final cls = x < width ~/ 2 ? leftClass : rightClass;
      out[base + cls] = 1.0;
    }
  }
  return out;
}

void main() {
  group('SelfieMulticlassResult.argmax', () {
    test('uniform-class tensor returns the same class everywhere', () {
      // The service hard-codes inputSize=256, so synthetic tensors
      // must be the full 256x256xN shape. Fill all pixels with the
      // hair-class peak.
      const n = SelfieMulticlassService.numClasses;
      const inSize = SelfieMulticlassService.inputSize;
      final scores = _buildSingleClassScores(
        width: inSize,
        height: inSize,
        numClasses: n,
        classIndex: SelfieMulticlassService.hairClass,
      );
      final result = SelfieMulticlassResult(scores: scores);
      final argmax = result.argmax();
      expect(argmax.length, inSize * inSize);
      // Every pixel should pick hair.
      for (var p = 0; p < argmax.length; p++) {
        expect(argmax[p], SelfieMulticlassService.hairClass,
            reason: 'pixel $p should pick hair (peak score)');
      }
    });

    test('split-class tensor returns left half=A, right half=B', () {
      // Full 256x256xN tensor with left half=hair, right half=clothes.
      const inSize = SelfieMulticlassService.inputSize;
      const n = SelfieMulticlassService.numClasses;
      final scores = _buildSplitScores(
        width: inSize,
        height: inSize,
        numClasses: n,
        leftClass: SelfieMulticlassService.hairClass,
        rightClass: SelfieMulticlassService.clothesClass,
      );
      final result = SelfieMulticlassResult(scores: scores);
      final argmax = result.argmax();
      // First row, left half = hair; right half = clothes.
      expect(argmax[0], SelfieMulticlassService.hairClass);
      expect(argmax[inSize ~/ 2 - 1], SelfieMulticlassService.hairClass);
      expect(argmax[inSize ~/ 2], SelfieMulticlassService.clothesClass);
      expect(argmax[inSize - 1], SelfieMulticlassService.clothesClass);
    });
  });

  group('SelfieMulticlassResult.maskForClasses', () {
    test('hair-class mask is 1.0 for hair pixels, 0.0 elsewhere', () {
      const inSize = SelfieMulticlassService.inputSize;
      const n = SelfieMulticlassService.numClasses;
      final scores = _buildSplitScores(
        width: inSize,
        height: inSize,
        numClasses: n,
        leftClass: SelfieMulticlassService.hairClass,
        rightClass: SelfieMulticlassService.clothesClass,
      );
      final result = SelfieMulticlassResult(scores: scores);
      final mask = result.maskForClasses(
        const {SelfieMulticlassService.hairClass},
      );
      expect(mask[0], 1.0); // hair pixel
      expect(mask[inSize ~/ 2], 0.0); // clothes pixel
    });

    test('hair+clothes mask covers both halves of the split frame', () {
      const inSize = SelfieMulticlassService.inputSize;
      const n = SelfieMulticlassService.numClasses;
      final scores = _buildSplitScores(
        width: inSize,
        height: inSize,
        numClasses: n,
        leftClass: SelfieMulticlassService.hairClass,
        rightClass: SelfieMulticlassService.clothesClass,
      );
      final result = SelfieMulticlassResult(scores: scores);
      final mask = result.maskForClasses(const {
        SelfieMulticlassService.hairClass,
        SelfieMulticlassService.clothesClass,
      });
      expect(mask[0], 1.0);
      expect(mask[inSize ~/ 2 - 1], 1.0);
      expect(mask[inSize ~/ 2], 1.0);
      expect(mask[inSize - 1], 1.0);
    });

    test('empty class set produces an all-zero mask', () {
      const inSize = SelfieMulticlassService.inputSize;
      const n = SelfieMulticlassService.numClasses;
      final scores = Float32List(inSize * inSize * n);
      // Class 0 (background) wins everywhere by default-zero scores.
      final result = SelfieMulticlassResult(scores: scores);
      final mask = result.maskForClasses(const {});
      expect(mask.every((v) => v == 0.0), isTrue);
    });
  });

  group('SelfieMulticlassResult.bilinearResize', () {
    test('identity size copies the source unchanged', () {
      final src = Float32List.fromList([0.0, 0.5, 1.0, 0.25]);
      final out = SelfieMulticlassResult.bilinearResize(
        src: src,
        srcWidth: 2,
        srcHeight: 2,
        dstWidth: 2,
        dstHeight: 2,
      );
      // Bilinear at the same size with the half-pixel offset should
      // reproduce the source.
      expect(out, hasLength(4));
      for (var i = 0; i < 4; i++) {
        expect(out[i], closeTo(src[i], 1e-6));
      }
    });

    test('upsample produces values inside the source range', () {
      // 2x2 → 4x4 with values [0, 1, 0, 1] in row-major. The output
      // should contain only values in [0, 1].
      final src = Float32List.fromList([0, 1, 0, 1]);
      final out = SelfieMulticlassResult.bilinearResize(
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

  group('RecolourTarget value class (XVI.47)', () {
    test('constructor preserves classes and target RGB', () {
      const t = RecolourTarget(
        classes: {SelfieMulticlassService.hairClass},
        targetR: 200,
        targetG: 100,
        targetB: 50,
      );
      expect(t.classes, {SelfieMulticlassService.hairClass});
      expect(t.targetR, 200);
      expect(t.targetG, 100);
      expect(t.targetB, 50);
    });

    test('hair + clothes target list models the dual-recolour case', () {
      // The picker sheet builds this exact shape for "Hair + Clothes"
      // mode; pin the construction so a refactor catches a regression.
      const targets = [
        RecolourTarget(
          classes: {SelfieMulticlassService.hairClass},
          targetR: 142,
          targetG: 36,
          targetB: 170,
        ),
        RecolourTarget(
          classes: {SelfieMulticlassService.clothesClass},
          targetR: 30,
          targetG: 136,
          targetB: 229,
        ),
      ];
      expect(targets, hasLength(2));
      expect(targets.first.classes, contains(SelfieMulticlassService.hairClass));
      expect(targets[1].classes, contains(SelfieMulticlassService.clothesClass));
    });
  });

  test('class index constants match the MediaPipe model card', () {
    // The model card is the source of truth — keep these constants in
    // sync or every recolour result will pull from the wrong channel.
    expect(SelfieMulticlassService.backgroundClass, 0);
    expect(SelfieMulticlassService.hairClass, 1);
    expect(SelfieMulticlassService.bodySkinClass, 2);
    expect(SelfieMulticlassService.faceSkinClass, 3);
    expect(SelfieMulticlassService.clothesClass, 4);
    expect(SelfieMulticlassService.accessoriesClass, 5);
    expect(SelfieMulticlassService.numClasses, 6);
  });
}
