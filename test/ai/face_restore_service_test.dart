import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:image_editor/ai/services/face_restore/face_restore_service.dart';

/// Phase XVI.79b — unit coverage for the parts of FaceRestoreService
/// that don't need a real ORT session. The full encode/decode flow
/// is covered manually via device testing (no easy way to bundle the
/// ~377 MB CodeFormer + face-detection harness inside `flutter test`).
///
/// Focus here is on the bits that historically broke silently:
///   * Constant IDs must match the manifest pins (XVI.78a, XVI.79a).
///   * `unscaleSignedChw` correctly maps `[-1, 1]` → `[0, 1]` AND
///     clamps out-of-range values — RestoreFormer++ used to spit
///     `[-3.3, 2.0]` and we don't want such garbage to bleed
///     through the byte cast.
///   * `flattenChw` recognises both `[1, 3, H, W]` and `[3, H, W]`
///     nesting depths.
///   * The default fidelity weight is the sensible `0.5`, not a
///     past accident (e.g. `1.0` = no restoration, which would
///     silently disable Restore Faces without erroring).
void main() {
  group('FaceRestoreService model constants (XVI.79b)', () {
    test('CodeFormer model id matches the manifest pin', () {
      expect(kCodeFormerModelId, 'codeformer_fp32');
    });

    test('Legacy RestoreFormer++ id is still exported (downloaded users)',
        () {
      // Even though XVI.79 routes face restore through CodeFormer,
      // the legacy constant must keep its value so any caller
      // resolving by id (e.g. the AI Models sheet) still finds
      // the right manifest entry.
      expect(kFaceRestoreModelId, 'restoreformer_pp_fp32');
    });

    test('Default fidelity weight is 0.5 — balanced restoration', () {
      // 0.0 = aggressive (ID shift); 1.0 = preserve input (no
      // visible restoration). 0.5 is the published sweet spot
      // for the kind of mild-to-moderate degradation Restore
      // Faces is invoked for.
      expect(kCodeFormerDefaultFidelityWeight, 0.5);
    });

    test('Fidelity weight is bounded [0, 1]', () {
      // Sanity guard against a typo bumping the const out of
      // CodeFormer's documented range.
      expect(kCodeFormerDefaultFidelityWeight, greaterThanOrEqualTo(0.0));
      expect(kCodeFormerDefaultFidelityWeight, lessThanOrEqualTo(1.0));
    });
  });

  group('FaceRestoreService.unscaleSignedChw', () {
    test('typical [-1, 1] values map to [0, 1] without clamping', () {
      final input = Float32List.fromList([-1.0, -0.5, 0.0, 0.5, 1.0]);
      final out = FaceRestoreService.unscaleSignedChw(input);
      expect(out, [0.0, 0.25, 0.5, 0.75, 1.0]);
    });

    test('out-of-range values clamp to [0, 1] — RestoreFormer++ tombstone',
        () {
      // XVI.79 testing surfaced that the broken dnnagy export
      // emits values like -3.3 and 2.0. unscaleSignedChw must
      // CLAMP those so they don't wrap through subsequent byte
      // casts — the rainbow noise the user reported came from
      // the model, not from this function (it correctly clamps).
      final input = Float32List.fromList([-3.5, -1.5, 1.5, 3.5]);
      final out = FaceRestoreService.unscaleSignedChw(input);
      expect(out, [0.0, 0.0, 1.0, 1.0]);
    });

    test('empty input returns empty output (no crash)', () {
      final out = FaceRestoreService.unscaleSignedChw(Float32List(0));
      expect(out.length, 0);
    });
  });

  group('FaceRestoreService.flattenChw', () {
    test('strips batch dim from [1, 3, H, W] nested lists', () {
      // 1×3×2×2 example
      final raw = [
        [
          [
            [1.0, 2.0],
            [3.0, 4.0],
          ],
          [
            [5.0, 6.0],
            [7.0, 8.0],
          ],
          [
            [9.0, 10.0],
            [11.0, 12.0],
          ],
        ],
      ];
      final out = FaceRestoreService.flattenChw(raw);
      expect(out, isNotNull);
      expect(out!.length, 12);
      // CHW layout: R-plane first, then G, then B
      expect(out.sublist(0, 4), [1.0, 2.0, 3.0, 4.0]);
      expect(out.sublist(4, 8), [5.0, 6.0, 7.0, 8.0]);
      expect(out.sublist(8, 12), [9.0, 10.0, 11.0, 12.0]);
    });

    test('accepts bare [3, H, W] nesting without the batch dim', () {
      final raw = [
        [
          [1.0, 2.0],
          [3.0, 4.0],
        ],
        [
          [5.0, 6.0],
          [7.0, 8.0],
        ],
        [
          [9.0, 10.0],
          [11.0, 12.0],
        ],
      ];
      final out = FaceRestoreService.flattenChw(raw);
      expect(out, isNotNull);
      expect(out!.length, 12);
      expect(out.first, 1.0);
      expect(out.last, 12.0);
    });

    test('returns null when channel count != 3', () {
      final raw = [
        [
          [1.0, 2.0],
          [3.0, 4.0],
        ],
      ];
      expect(FaceRestoreService.flattenChw(raw), isNull);
    });

    test('returns null on empty input', () {
      expect(FaceRestoreService.flattenChw([]), isNull);
      expect(FaceRestoreService.flattenChw(null), isNull);
    });
  });

  group('FaceRestoreException', () {
    test('toString without cause shows message only', () {
      const e = FaceRestoreException('boom');
      expect(e.toString(), 'FaceRestoreException: boom');
    });

    test('toString with cause appends "caused by"', () {
      const cause = 'MlRuntimeException(stage: run, message: kernel)';
      const e = FaceRestoreException('decode failed', cause: cause);
      final s = e.toString();
      expect(s, contains('FaceRestoreException: decode failed'));
      expect(s, contains('caused by'));
      expect(s, contains('kernel'));
    });
  });

  group('SquareCrop value type', () {
    test('equality + hashCode work like a value class', () {
      const a = SquareCrop(x: 10, y: 20, size: 100);
      const b = SquareCrop(x: 10, y: 20, size: 100);
      const c = SquareCrop(x: 11, y: 20, size: 100);
      expect(a, b);
      expect(a.hashCode, b.hashCode);
      expect(a, isNot(c));
    });

    test('toString is readable', () {
      const a = SquareCrop(x: 10, y: 20, size: 100);
      expect(a.toString(), 'SquareCrop(x=10, y=20, size=100)');
    });
  });
}
