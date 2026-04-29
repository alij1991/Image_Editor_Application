import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:image_editor/ai/services/style_transfer/photo_wct_service.dart';

/// Phase XVI.57 — pin the pure-Dart helpers in `PhotoWctService`.
/// The full inference path needs a live ORT session and isn't
/// exercisable from unit tests. The pieces below cover what's
/// testable without a model:
///
///   1. `pickInputNames` resolves the (content, style) pair from
///      common naming conventions and falls back to positional
///      order when role-name matching fails.
///   2. CHW flattening tolerates `[3, H, W]` and `[1, 3, H, W]`.
///   3. `chwToRgba` packs values with clamping and alpha = 255.
///   4. InputNamePair value-class equality + kPhotoWctModelId.
void main() {
  group('PhotoWctService.pickInputNames', () {
    test('exact match on "content" + "style" wins', () {
      final names = PhotoWctService.pickInputNames(['content', 'style']);
      expect(names, isNotNull);
      expect(names!.content, 'content');
      expect(names.style, 'style');
    });

    test('matches "content_image" + "style_image" suffix variants', () {
      final names = PhotoWctService.pickInputNames(
        ['content_image', 'style_image'],
      );
      expect(names!.content, 'content_image');
      expect(names.style, 'style_image');
    });

    test('matches "c" + "s" abbreviations', () {
      final names = PhotoWctService.pickInputNames(['c', 's']);
      expect(names!.content, 'c');
      expect(names.style, 's');
    });

    test('reverse declared order still resolves correctly', () {
      // Author named the inputs unhelpfully — first is style, second
      // is content. Role-name matching wins over positional.
      final names = PhotoWctService.pickInputNames(['style', 'content']);
      expect(names!.content, 'content');
      expect(names.style, 'style');
    });

    test('falls back to positional when no role names match', () {
      // Neither name has a role hint → first becomes content, second
      // becomes style per PhotoWCT2's published declared order.
      final names = PhotoWctService.pickInputNames(['x', 'y']);
      expect(names!.content, 'x');
      expect(names.style, 'y');
    });

    test('rejects fewer than 2 inputs', () {
      expect(PhotoWctService.pickInputNames(['content']), isNull);
      expect(PhotoWctService.pickInputNames(const []), isNull);
    });

    test('rejects identical names (would overwrite content)', () {
      // pickInputNames matches 'content' to the first 'content' entry,
      // then can't match 'style' to anything, falls back to positional
      // → second 'content' = style. The two slots end up identical,
      // which would overwrite the dict. Helper returns null.
      final names = PhotoWctService.pickInputNames(['content', 'content']);
      expect(names, isNull);
    });
  });

  group('PhotoWctService.flattenChw', () {
    test('null and empty inputs return null', () {
      expect(PhotoWctService.flattenChw(null), isNull);
      expect(PhotoWctService.flattenChw(const <dynamic>[]), isNull);
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
      final out = PhotoWctService.flattenChw(raw);
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
      final out = PhotoWctService.flattenChw(raw);
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
        ], // only 2 channels
      ];
      expect(PhotoWctService.flattenChw(raw), isNull);
    });

    test('non-numeric value returns null', () {
      final raw = [
        [
          ['oops']
        ],
        [
          [0.2]
        ],
        [
          [0.3]
        ],
      ];
      expect(PhotoWctService.flattenChw(raw), isNull);
    });
  });

  group('PhotoWctService.chwToRgba', () {
    test('identity size produces a directly-packable RGBA', () {
      // 1×1 image × 3 channels: [R=0.5, G=0.25, B=1.0]
      final chw = Float32List.fromList([0.5, 0.25, 1.0]);
      final out = PhotoWctService.chwToRgba(
        chw: chw,
        chwSize: 1,
        dstWidth: 1,
        dstHeight: 1,
      );
      expect(out, hasLength(4));
      expect(out[0], 128);
      expect(out[1], 64);
      expect(out[2], 255);
      expect(out[3], 255);
    });

    test('clamps out-of-range floats to [0, 255]', () {
      final chw = Float32List.fromList([-0.5, 0.5, 1.5]);
      final out = PhotoWctService.chwToRgba(
        chw: chw,
        chwSize: 1,
        dstWidth: 1,
        dstHeight: 1,
      );
      expect(out[0], 0);
      expect(out[1], 128);
      expect(out[2], 255);
      expect(out[3], 255);
    });

    test('upsample 2×2 → 4×4 produces values inside [0, 255]', () {
      final chw = Float32List(3 * 2 * 2);
      for (var i = 0; i < 4; i++) {
        chw[i] = 0.5;
        chw[4 + i] = 0.25;
        chw[8 + i] = 1.0;
      }
      final out = PhotoWctService.chwToRgba(
        chw: chw,
        chwSize: 2,
        dstWidth: 4,
        dstHeight: 4,
      );
      expect(out, hasLength(4 * 4 * 4));
      for (var p = 0; p < 16; p++) {
        final i = p * 4;
        expect(out[i], inInclusiveRange(120, 135));
        expect(out[i + 1], inInclusiveRange(60, 70));
        expect(out[i + 2], 255);
        expect(out[i + 3], 255);
      }
    });
  });

  group('InputNamePair value class', () {
    test('equality + hashCode pin both names', () {
      const a = InputNamePair(content: 'c', style: 's');
      const b = InputNamePair(content: 'c', style: 's');
      const c = InputNamePair(content: 'c', style: 'z');
      expect(a, b);
      expect(a == c, isFalse);
      expect(a.hashCode, b.hashCode);
    });

    test('toString includes both names', () {
      const a = InputNamePair(content: 'c', style: 's');
      expect(a.toString(), contains('c'));
      expect(a.toString(), contains('s'));
    });
  });

  test('kPhotoWctModelId matches the manifest entry', () {
    expect(kPhotoWctModelId, 'photo_wct2_fp16');
  });
}
