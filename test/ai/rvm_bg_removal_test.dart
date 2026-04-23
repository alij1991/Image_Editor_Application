import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:image_editor/ai/services/bg_removal/rvm_bg_removal.dart';

/// Phase XV.1: unit tests for the pure-Dart helpers inside
/// [RvmBgRemoval] — the inference path itself needs a real ONNX
/// session and is covered by manual device testing during Phase XV.
void main() {
  group('RvmBgRemoval.flattenMaskForTest', () {
    test('returns null for non-list input', () {
      expect(RvmBgRemoval.flattenMaskForTest(null), isNull);
      expect(RvmBgRemoval.flattenMaskForTest(42), isNull);
    });

    test('returns null for empty outer list', () {
      expect(RvmBgRemoval.flattenMaskForTest(const []), isNull);
    });

    test('flattens a [1][1][H][W] nested tensor in row-major order', () {
      final raw = [
        [
          [
            [0.1, 0.2, 0.3],
            [0.4, 0.5, 0.6],
          ],
        ],
      ];
      final flat = RvmBgRemoval.flattenMaskForTest(raw);
      expect(flat, isNotNull);
      expect(flat!.length, 6);
      expect(flat[0], closeTo(0.1, 1e-6));
      expect(flat[5], closeTo(0.6, 1e-6));
    });

    test('returns null when a row has the wrong width', () {
      final raw = [
        [
          [
            [0.1, 0.2, 0.3],
            [0.4, 0.5], // short row
          ],
        ],
      ];
      expect(RvmBgRemoval.flattenMaskForTest(raw), isNull);
    });

    test('returns null when a non-numeric leaf is found', () {
      final raw = [
        [
          [
            [0.1, 'oops', 0.3],
          ],
        ],
      ];
      expect(RvmBgRemoval.flattenMaskForTest(raw), isNull);
    });
  });

  group('RvmBgRemoval.flattenFgrForTest', () {
    test('returns null for non-list or empty input', () {
      expect(RvmBgRemoval.flattenFgrForTest(null), isNull);
      expect(RvmBgRemoval.flattenFgrForTest(42), isNull);
      expect(RvmBgRemoval.flattenFgrForTest(const []), isNull);
    });

    test('flattens a [1, 3, H, W] CHW tensor in channel-major order', () {
      // 1 batch, 3 channels, 2x2 spatial:
      //   R: [[0.1, 0.2], [0.3, 0.4]]
      //   G: [[0.5, 0.6], [0.7, 0.8]]
      //   B: [[0.9, 0.95], [0.99, 1.0]]
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
            [0.9, 0.95],
            [0.99, 1.0],
          ],
        ],
      ];
      final flat = RvmBgRemoval.flattenFgrForTest(raw);
      expect(flat, isNotNull);
      expect(flat!.length, 12); // 3 * 2 * 2
      // R plane first
      expect(flat[0], closeTo(0.1, 1e-6));
      expect(flat[3], closeTo(0.4, 1e-6));
      // G plane
      expect(flat[4], closeTo(0.5, 1e-6));
      expect(flat[7], closeTo(0.8, 1e-6));
      // B plane
      expect(flat[8], closeTo(0.9, 1e-6));
      expect(flat[11], closeTo(1.0, 1e-6));
    });

    test('returns null when channel count is not 3', () {
      final raw = [
        [
          [
            [0.1, 0.2],
          ],
          [
            [0.3, 0.4],
          ],
          // only 2 channels — should fail
        ],
      ];
      expect(RvmBgRemoval.flattenFgrForTest(raw), isNull);
    });

    test('returns null on ragged row lengths', () {
      final raw = [
        [
          [
            [0.1, 0.2, 0.3],
            [0.4, 0.5], // short
          ],
          [
            [0.1, 0.2, 0.3],
            [0.4, 0.5, 0.6],
          ],
          [
            [0.1, 0.2, 0.3],
            [0.4, 0.5, 0.6],
          ],
        ],
      ];
      expect(RvmBgRemoval.flattenFgrForTest(raw), isNull);
    });
  });

  group('RvmBgRemoval.buildCleanSubjectRgbaForTest', () {
    test('identity resize: 2×2 fgr + mask → 2×2 RGBA', () {
      // Fgr (CHW): R=[0, 0.5, 1, 1], G=[0, 0, 1, 1], B=[0, 0, 0, 1]
      //   pixel (0,0) = (0, 0, 0)
      //   pixel (1,0) = (0.5, 0, 0)
      //   pixel (0,1) = (1, 1, 0)
      //   pixel (1,1) = (1, 1, 1)
      final fgr = Float32List.fromList([
        0.0, 0.5, 1.0, 1.0, // R
        0.0, 0.0, 1.0, 1.0, // G
        0.0, 0.0, 0.0, 1.0, // B
      ]);
      final mask = Float32List.fromList([0.0, 0.5, 0.8, 1.0]);
      final out = RvmBgRemoval.buildCleanSubjectRgbaForTest(
        fgr: fgr,
        mask: mask,
        tensorSize: 2,
        outputWidth: 2,
        outputHeight: 2,
      );
      expect(out.length, 16);
      // Pixel (0, 0): RGB=(0,0,0), A=0
      expect(out[0], 0);
      expect(out[1], 0);
      expect(out[2], 0);
      expect(out[3], 0);
      // Pixel (1, 0): RGB=(128,0,0), A≈128
      expect(out[4], closeTo(128, 1));
      expect(out[5], 0);
      expect(out[6], 0);
      expect(out[7], closeTo(128, 1));
      // Pixel (1, 1): RGB=(255, 255, 255), A=255
      expect(out[12], 255);
      expect(out[13], 255);
      expect(out[14], 255);
      expect(out[15], 255);
    });

    test('upsamples fgr colours and mask alpha together', () {
      // Solid red subject everywhere with alpha=1 everywhere.
      final fgr = Float32List(3 * 4);
      for (int i = 0; i < 4; i++) {
        fgr[i] = 1.0; // R=1
        // G, B stay 0
      }
      final mask = Float32List.fromList([1.0, 1.0, 1.0, 1.0]);
      final out = RvmBgRemoval.buildCleanSubjectRgbaForTest(
        fgr: fgr,
        mask: mask,
        tensorSize: 2,
        outputWidth: 10,
        outputHeight: 10,
      );
      expect(out.length, 10 * 10 * 4);
      // Every output pixel is solid red with full alpha.
      for (int i = 0; i < out.length; i += 4) {
        expect(out[i], 255);
        expect(out[i + 1], 0);
        expect(out[i + 2], 0);
        expect(out[i + 3], 255);
      }
    });

    test('clamps fgr values outside [0, 1] gracefully', () {
      // RVM occasionally emits slightly-out-of-range floats on
      // extreme highlights (e.g. 1.01, -0.02). The clamp in the
      // packer should keep the output byte-valid.
      final fgr = Float32List.fromList([
        1.5, -0.1, 0.5, 0.5, // R
        -0.3, 2.0, 0.5, 0.5, // G
        0.5, 0.5, 0.5, 0.5, // B
      ]);
      final mask = Float32List.fromList([1.0, 1.0, 1.0, 1.0]);
      final out = RvmBgRemoval.buildCleanSubjectRgbaForTest(
        fgr: fgr,
        mask: mask,
        tensorSize: 2,
        outputWidth: 2,
        outputHeight: 2,
      );
      // Over-range pixel (0,0): R=1.5→255, G=-0.3→0.
      expect(out[0], 255);
      expect(out[1], 0);
      // Over-range pixel (1,0): R=-0.1→0, G=2.0→255.
      expect(out[4], 0);
      expect(out[5], 255);
    });
  });

  group('RvmBgRemoval.findOutputForTest', () {
    test('finds the exact match first', () {
      final name = RvmBgRemoval.findOutputForTest(
        ['pha', 'fgr'],
        ['pha', 'alpha'],
      );
      expect(name, 'pha');
    });

    test('falls through to the second candidate when the first misses', () {
      // Only `alpha` is exposed as an exact name here; 'pha' won't
      // match anything because neither output ends with 'pha'.
      final name = RvmBgRemoval.findOutputForTest(
        ['fgr', 'alpha'],
        ['pha', 'alpha'],
      );
      expect(name, 'alpha');
    });

    test('matches a namespaced suffix (case-insensitive)', () {
      // Some exports prefix outputs with a graph namespace. The
      // suffix match is what lets `"model/pha"` still resolve to
      // the `pha` candidate.
      final name = RvmBgRemoval.findOutputForTest(
        ['model/pha', 'model/fgr'],
        ['pha'],
      );
      expect(name, 'model/pha');
    });

    test('returns null when no candidate matches', () {
      final name = RvmBgRemoval.findOutputForTest(
        ['output_0', 'output_1'],
        ['pha', 'alpha'],
      );
      expect(name, isNull);
    });
  });
}
