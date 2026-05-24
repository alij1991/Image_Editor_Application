import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:image_editor/ai/services/segment/mobile_sam_service.dart';

/// Phase XVI.78b — unit coverage for the parts of MobileSamSegmenter
/// that don't need a real ORT model loaded. The encode + decode flows
/// are covered manually via device testing (no easy way to bundle the
/// ~45 MB encoder + decoder in test fixtures and run them inside a
/// `flutter test` host).
void main() {
  group('MobileSamPoint.fromCanvas', () {
    test('identity scale: canvas dims == decoded dims passes coords through',
        () {
      final p = MobileSamPoint.fromCanvas(
        canvasX: 100,
        canvasY: 200,
        canvasWidth: 512,
        canvasHeight: 768,
        decodedWidth: 512,
        decodedHeight: 768,
        foreground: true,
      );
      expect(p.x, 100);
      expect(p.y, 200);
      expect(p.foreground, isTrue);
    });

    test('2× upscale: canvas tap doubles into decoded space', () {
      final p = MobileSamPoint.fromCanvas(
        canvasX: 100,
        canvasY: 200,
        canvasWidth: 256,
        canvasHeight: 384,
        decodedWidth: 512,
        decodedHeight: 768,
        foreground: true,
      );
      expect(p.x, 200);
      expect(p.y, 400);
    });

    test('downscale: canvas tap halves into decoded space', () {
      final p = MobileSamPoint.fromCanvas(
        canvasX: 200,
        canvasY: 400,
        canvasWidth: 1024,
        canvasHeight: 1536,
        decodedWidth: 512,
        decodedHeight: 768,
        foreground: true,
      );
      expect(p.x, 100);
      expect(p.y, 200);
    });

    test('canvas dim <= 0 falls back to 1 to avoid divide-by-zero', () {
      final p = MobileSamPoint.fromCanvas(
        canvasX: 50,
        canvasY: 50,
        canvasWidth: 0, // would explode without the math.max guard
        canvasHeight: -10,
        decodedWidth: 100,
        decodedHeight: 100,
        foreground: false,
      );
      // canvas=0 / canvas=negative ⇒ scale = decoded/1 = decoded;
      // so tap at (50,50) maps to (50*100, 50*100) = (5000, 5000).
      // That's an out-of-range coord; SAM tolerates it but the UI
      // should never produce a zero canvas — this just proves we
      // don't crash.
      expect(p.x, 5000);
      expect(p.y, 5000);
      expect(p.foreground, isFalse);
    });

    test('foreground flag is forwarded verbatim', () {
      final fg = MobileSamPoint.fromCanvas(
        canvasX: 0,
        canvasY: 0,
        canvasWidth: 1,
        canvasHeight: 1,
        decodedWidth: 1,
        decodedHeight: 1,
        foreground: true,
      );
      final bg = MobileSamPoint.fromCanvas(
        canvasX: 0,
        canvasY: 0,
        canvasWidth: 1,
        canvasHeight: 1,
        decodedWidth: 1,
        decodedHeight: 1,
        foreground: false,
      );
      expect(fg.foreground, isTrue);
      expect(bg.foreground, isFalse);
    });
  });

  group('MobileSamMask convenience getters', () {
    test('empty mask reports 0 foreground + 0.0 ratio', () {
      final mask = MobileSamMask(
        alpha: Uint8List(100),
        width: 10,
        height: 10,
        iou: 0.5,
      );
      expect(mask.foregroundPixelCount, 0);
      expect(mask.foregroundRatio, 0.0);
    });

    test('full mask reports H*W foreground + 1.0 ratio', () {
      final alpha = Uint8List(100);
      for (var i = 0; i < alpha.length; i++) {
        alpha[i] = 255;
      }
      final mask = MobileSamMask(
        alpha: alpha,
        width: 10,
        height: 10,
        iou: 0.9,
      );
      expect(mask.foregroundPixelCount, 100);
      expect(mask.foregroundRatio, 1.0);
    });

    test('partial mask reports correct stats', () {
      final alpha = Uint8List(100);
      // Mark the first 25 pixels as foreground.
      for (var i = 0; i < 25; i++) {
        alpha[i] = 255;
      }
      final mask = MobileSamMask(
        alpha: alpha,
        width: 10,
        height: 10,
        iou: 0.8,
      );
      expect(mask.foregroundPixelCount, 25);
      expect(mask.foregroundRatio, 0.25);
    });

    test('any non-zero alpha counts as foreground', () {
      // The decode pass writes 0 or 255, but the convenience getter
      // shouldn't assume that — a partial-transparency mask still
      // means "this pixel belongs to the subject."
      final alpha = Uint8List.fromList([0, 1, 128, 254, 255]);
      final mask = MobileSamMask(
        alpha: alpha,
        width: 5,
        height: 1,
        iou: 0.7,
      );
      expect(mask.foregroundPixelCount, 4); // everything except 0
      expect(mask.foregroundRatio, 4 / 5);
    });

    test('lowResLogits is null by default; passes through when set', () {
      final maskNoLowRes = MobileSamMask(
        alpha: Uint8List(0),
        width: 0,
        height: 0,
        iou: 0,
      );
      expect(maskNoLowRes.lowResLogits, isNull);

      final logits = Float32List(256 * 256);
      final maskWithLowRes = MobileSamMask(
        alpha: Uint8List(0),
        width: 0,
        height: 0,
        iou: 0,
        lowResLogits: logits,
      );
      expect(maskWithLowRes.lowResLogits, same(logits));
    });
  });

  group('MobileSamEmbedding', () {
    test('captures decoded image dimensions + source path', () {
      final emb = MobileSamEmbedding(
        sourcePath: '/tmp/cat.jpg',
        decodedWidth: 1024,
        decodedHeight: 768,
        data: Float32List(1 * 256 * 64 * 64),
      );
      expect(emb.sourcePath, '/tmp/cat.jpg');
      expect(emb.decodedWidth, 1024);
      expect(emb.decodedHeight, 768);
      expect(emb.data.length, 1 * 256 * 64 * 64);
    });
  });

  group('MobileSamException', () {
    test('toString without cause shows message only', () {
      const e = MobileSamException('boom');
      expect(e.toString(), 'MobileSamException: boom');
    });

    test('toString with cause appends "caused by"', () {
      const cause = 'MlRuntimeException(stage: run, message: ORT crash)';
      const e = MobileSamException('decode failed', cause: cause);
      final s = e.toString();
      expect(s, contains('MobileSamException: decode failed'));
      expect(s, contains('caused by'));
      expect(s, contains('ORT crash'));
    });
  });

  group('manifest constants', () {
    test('model IDs match the manifest entries pinned in XVI.78a', () {
      // Regression guard: if a future commit renames the manifest
      // entries (or the constants here), this trips immediately so
      // the factory + tests don't silently fall out of sync.
      expect(MobileSamSegmenter.kEncoderModelId, 'mobile_sam_encoder');
      expect(MobileSamSegmenter.kDecoderModelId, 'mobile_sam_decoder');
    });

    test('default encoder input cap matches SAM training resolution', () {
      // SAM was trained at 1024; deviating from this is a quality
      // regression worth a test, not a stylistic preference.
      expect(MobileSamSegmenter.kDefaultEncoderInputMaxDim, 1024);
    });
  });
}
