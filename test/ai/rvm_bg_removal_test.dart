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
}
