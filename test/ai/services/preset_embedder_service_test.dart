import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:image_editor/ai/services/preset_suggest/preset_embedder_service.dart';

/// Phase XVI.58 — pin the pure-Dart helpers in
/// `PresetEmbedderService`. The full inference path needs a live
/// ORT session; these tests cover what's testable without a model:
///
///   1. Input-name matching tolerates the common conventions
///      ('input', 'pixel_values', 'image', 'sample').
///   2. Embedding flattening tolerates `[1, D]` and bare `[D]`.
///   3. L2-normalisation produces unit-length vectors and handles
///      zero-magnitude inputs without div-by-zero.
///   4. kPresetEmbedderModelId matches the manifest entry.
void main() {
  group('PresetEmbedderService.pickInputName', () {
    test('exact match on "input" wins', () {
      final out = PresetEmbedderService.pickInputName(['input']);
      expect(out, 'input');
    });

    test('"pixel_values" matches the HF transformers convention', () {
      final out = PresetEmbedderService.pickInputName(['pixel_values']);
      expect(out, 'pixel_values');
    });

    test('"image" matches when pixel_values missing', () {
      final out = PresetEmbedderService.pickInputName(['image', 'mask']);
      expect(out, 'image');
    });

    test('falls back to first when nothing matches', () {
      final out = PresetEmbedderService.pickInputName(['weird_name']);
      expect(out, 'weird_name');
    });

    test('empty list returns null', () {
      expect(PresetEmbedderService.pickInputName(const []), isNull);
    });
  });

  group('PresetEmbedderService.flattenEmbedding', () {
    test('null and empty inputs return null', () {
      expect(PresetEmbedderService.flattenEmbedding(null), isNull);
      expect(PresetEmbedderService.flattenEmbedding(const <dynamic>[]), isNull);
    });

    test('[1, D] tensor (with batch) flattens to D', () {
      final raw = [
        [0.1, 0.2, 0.3, 0.4, 0.5],
      ];
      final out = PresetEmbedderService.flattenEmbedding(raw);
      expect(out, isNotNull);
      expect(out!.length, 5);
      expect(out[0], closeTo(0.1, 1e-6));
      expect(out[4], closeTo(0.5, 1e-6));
    });

    test('bare [D] tensor (no batch) flattens directly', () {
      final raw = [0.1, 0.2, 0.3];
      final out = PresetEmbedderService.flattenEmbedding(raw);
      expect(out, isNotNull);
      expect(out!.length, 3);
      expect(out[2], closeTo(0.3, 1e-6));
    });

    test('non-numeric value returns null', () {
      final raw = [
        [0.1, 'oops', 0.3],
      ];
      expect(PresetEmbedderService.flattenEmbedding(raw), isNull);
    });
  });

  group('PresetEmbedderService.l2Normalise', () {
    test('unit-length output for non-zero input', () {
      final v = Float32List.fromList([3.0, 4.0]);
      PresetEmbedderService.l2Normalise(v);
      // 3-4-5 triangle: magnitude collapses to 1.
      expect(v[0], closeTo(0.6, 1e-6));
      expect(v[1], closeTo(0.8, 1e-6));
      // Sum of squares ≈ 1.
      var sumSq = 0.0;
      for (final x in v) {
        sumSq += x * x;
      }
      expect(sumSq, closeTo(1.0, 1e-6));
    });

    test('zero-magnitude input returns unchanged (no div-by-0)', () {
      final v = Float32List.fromList([0.0, 0.0, 0.0]);
      final out = PresetEmbedderService.l2Normalise(v);
      // Identity — every component still 0.
      for (final x in out) {
        expect(x, 0.0);
      }
    });

    test('returns the same Float32List for chaining', () {
      final v = Float32List.fromList([1.0, 0.0]);
      final out = PresetEmbedderService.l2Normalise(v);
      expect(identical(out, v), isTrue);
    });
  });

  group('PresetEmbedderException', () {
    test('toString exposes message and cause', () {
      const e = PresetEmbedderException('oops', cause: 'underlying');
      expect(e.toString(), contains('oops'));
      expect(e.toString(), contains('underlying'));
    });

    test('toString without cause is concise', () {
      const e = PresetEmbedderException('oops');
      expect(e.toString(), 'PresetEmbedderException: oops');
    });
  });

  test('kPresetEmbedderModelId matches the manifest entry', () {
    expect(kPresetEmbedderModelId, 'mobilevit_v2_0_5_int8');
  });
}
