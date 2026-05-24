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

  group('RvmBgRemoval.computeTargetDims (XVI.86)', () {
    test('1024×768 source under cap → identity dims', () {
      // Field case: photo-camera 4:3 photo. Pre-XVI.86 was crushed
      // to 512×512 SQUARE; now matches source 1:1.
      final (w, h) = RvmBgRemoval.computeTargetDims(
        srcWidth: 1024,
        srcHeight: 768,
        maxInputDim: 1024,
      );
      expect(w, 1024);
      expect(h, 768);
    });

    test('preserves aspect ratio when source exceeds cap', () {
      final (w, h) = RvmBgRemoval.computeTargetDims(
        srcWidth: 2048,
        srcHeight: 1536,
        maxInputDim: 1024,
      );
      expect(w, 1024);
      expect(h, 768);
    });

    test('portrait orientation clamps height not width', () {
      final (w, h) = RvmBgRemoval.computeTargetDims(
        srcWidth: 1536,
        srcHeight: 2048,
        maxInputDim: 1024,
      );
      expect(w, 768);
      expect(h, 1024);
    });

    test('rounds down to /32 (MobileNetV3 stride alignment)', () {
      // 1023 → 992 (/32); 769 → 768.
      final (w, h) = RvmBgRemoval.computeTargetDims(
        srcWidth: 1023,
        srcHeight: 769,
        maxInputDim: 1024,
      );
      expect(w, 992);
      expect(h, 768);
    });

    test('1×1 degenerate still satisfies /32 minimum', () {
      final (w, h) = RvmBgRemoval.computeTargetDims(
        srcWidth: 1,
        srcHeight: 1,
        maxInputDim: 1024,
      );
      expect(w, 32);
      expect(h, 32);
    });

    test('zero / negative dims return safe 32×32', () {
      final (w, h) = RvmBgRemoval.computeTargetDims(
        srcWidth: 0,
        srcHeight: 100,
        maxInputDim: 1024,
      );
      expect(w, 32);
      expect(h, 32);
    });
  });

  group('RvmBgRemoval.downsampleRatioFor (XVI.86)', () {
    test('< 720p input → 0.5', () {
      expect(RvmBgRemoval.downsampleRatioFor(640), 0.5);
      expect(RvmBgRemoval.downsampleRatioFor(800), 0.5);
    });

    test('~720p input → 0.375', () {
      expect(RvmBgRemoval.downsampleRatioFor(801), 0.375);
      expect(RvmBgRemoval.downsampleRatioFor(1024), 0.375);
      expect(RvmBgRemoval.downsampleRatioFor(1280), 0.375);
    });

    test('~1080p input → 0.25', () {
      expect(RvmBgRemoval.downsampleRatioFor(1301), 0.25);
      expect(RvmBgRemoval.downsampleRatioFor(1920), 0.25);
      expect(RvmBgRemoval.downsampleRatioFor(2000), 0.25);
    });

    test('4K input → 0.125', () {
      expect(RvmBgRemoval.downsampleRatioFor(2001), 0.125);
      expect(RvmBgRemoval.downsampleRatioFor(3840), 0.125);
      expect(RvmBgRemoval.downsampleRatioFor(4096), 0.125);
    });

    test('the default maxInputDim 1024 maps to the 0.375 ratio', () {
      // Regression guard: the typical phone photo (1024 long-edge
      // after our cap) should land in RVM's "720p" tier, where
      // 0.375 is the published recommendation. Pre-XVI.86 we hard-
      // coded 0.25 — over-aggressive for 512² input, even worse
      // for 1024 native.
      expect(RvmBgRemoval.downsampleRatioFor(RvmBgRemoval.kDefaultMaxInputDim),
          0.375);
    });
  });
}
