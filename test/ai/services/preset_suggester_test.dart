import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:image_editor/ai/services/preset_suggest/preset_suggester.dart';

/// Phase XVI.58 — pin `PresetSuggester` end-to-end.
///
///   1. JSON parsing — happy path + every malformed-payload branch.
///   2. Cosine kNN — basic correctness, top-k, ranking on ties.
///   3. Dimension mismatch / empty library / k <= 0 → empty result
///      (silent fallback per project convention).
///   4. minSimilarity threshold filters low-similarity hits.
void main() {
  group('PresetEmbeddingLibrary.parse', () {
    test('null / empty / blank input returns the empty library', () {
      expect(PresetEmbeddingLibrary.parse(null).entries, isEmpty);
      expect(PresetEmbeddingLibrary.parse('').entries, isEmpty);
      expect(PresetEmbeddingLibrary.parse('   ').entries, isEmpty);
    });

    test('happy path parses every field', () {
      const jsonStr = '''
      {
        "version": 1,
        "modelId": "mobilevit_v2_0_5_int8",
        "embeddingDim": 3,
        "entries": [
          {"presetId": "p1", "embedding": [0.1, 0.2, 0.3]},
          {"presetId": "p2", "embedding": [0.4, 0.5, 0.6]}
        ]
      }
      ''';
      final lib = PresetEmbeddingLibrary.parse(jsonStr);
      expect(lib.version, 1);
      expect(lib.modelId, 'mobilevit_v2_0_5_int8');
      expect(lib.embeddingDim, 3);
      expect(lib.entries, hasLength(2));
      expect(lib.entries.first.presetId, 'p1');
      expect(lib.entries.first.embedding[0], closeTo(0.1, 1e-6));
      expect(lib.entries.last.embedding[2], closeTo(0.6, 1e-6));
    });

    test('rejects non-object root', () {
      expect(
        () => PresetEmbeddingLibrary.parse('[]'),
        throwsFormatException,
      );
    });

    test('rejects non-positive version', () {
      expect(
        () => PresetEmbeddingLibrary.parse('''
          {"version": 0, "modelId": "m", "embeddingDim": 2, "entries": []}
        '''),
        throwsFormatException,
      );
    });

    test('rejects empty modelId', () {
      expect(
        () => PresetEmbeddingLibrary.parse('''
          {"version": 1, "modelId": "", "embeddingDim": 2, "entries": []}
        '''),
        throwsFormatException,
      );
    });

    test('rejects non-positive embeddingDim', () {
      expect(
        () => PresetEmbeddingLibrary.parse('''
          {"version": 1, "modelId": "m", "embeddingDim": 0, "entries": []}
        '''),
        throwsFormatException,
      );
    });

    test('rejects entry with mismatched embedding length', () {
      expect(
        () => PresetEmbeddingLibrary.parse('''
          {
            "version": 1, "modelId": "m", "embeddingDim": 3,
            "entries": [{"presetId": "p1", "embedding": [0.1, 0.2]}]
          }
        '''),
        throwsFormatException,
      );
    });

    test('rejects non-numeric value inside an embedding', () {
      expect(
        () => PresetEmbeddingLibrary.parse('''
          {
            "version": 1, "modelId": "m", "embeddingDim": 2,
            "entries": [{"presetId": "p1", "embedding": [0.1, "x"]}]
          }
        '''),
        throwsFormatException,
      );
    });

    test('rejects entry without presetId', () {
      expect(
        () => PresetEmbeddingLibrary.parse('''
          {
            "version": 1, "modelId": "m", "embeddingDim": 2,
            "entries": [{"embedding": [0.1, 0.2]}]
          }
        '''),
        throwsFormatException,
      );
    });
  });

  group('PresetSuggester.suggest', () {
    PresetEmbeddingLibrary buildLibrary() {
      return PresetEmbeddingLibrary.parse('''
        {
          "version": 1,
          "modelId": "mobilevit_v2_0_5_int8",
          "embeddingDim": 3,
          "entries": [
            {"presetId": "warm",     "embedding": [1.0, 0.0, 0.0]},
            {"presetId": "neutral",  "embedding": [0.0, 1.0, 0.0]},
            {"presetId": "cool",     "embedding": [0.0, 0.0, 1.0]},
            {"presetId": "warm-ish", "embedding": [0.9, 0.1, 0.0]}
          ]
        }
      ''');
    }

    test('top-1 retrieves the exact match', () {
      final s = PresetSuggester(library: buildLibrary());
      final out = s.suggest(
        queryEmbedding: Float32List.fromList([1.0, 0.0, 0.0]),
        k: 1,
      );
      expect(out, hasLength(1));
      expect(out.first.presetId, 'warm');
      expect(out.first.score, closeTo(1.0, 1e-6));
    });

    test('top-2 brings up the close runner-up', () {
      final s = PresetSuggester(library: buildLibrary());
      final out = s.suggest(
        queryEmbedding: Float32List.fromList([1.0, 0.0, 0.0]),
        k: 2,
      );
      expect(out, hasLength(2));
      expect(out.first.presetId, 'warm');
      expect(out[1].presetId, 'warm-ish');
    });

    test('orthogonal entries score 0', () {
      final s = PresetSuggester(library: buildLibrary());
      final out = s.suggest(
        queryEmbedding: Float32List.fromList([1.0, 0.0, 0.0]),
        k: 4,
      );
      // 'neutral' and 'cool' are perpendicular to 'warm' — score 0.
      final byId = {for (final r in out) r.presetId: r.score};
      expect(byId['neutral'], closeTo(0.0, 1e-6));
      expect(byId['cool'], closeTo(0.0, 1e-6));
    });

    test('minSimilarity filters low-similarity entries', () {
      final s = PresetSuggester(library: buildLibrary());
      final out = s.suggest(
        queryEmbedding: Float32List.fromList([1.0, 0.0, 0.0]),
        k: 4,
        minSimilarity: 0.5,
      );
      // Only 'warm' (1.0) and 'warm-ish' (~0.994) clear the threshold.
      expect(out.map((r) => r.presetId).toList(), ['warm', 'warm-ish']);
    });

    test('dimension mismatch returns empty (silent fallback)', () {
      final s = PresetSuggester(library: buildLibrary());
      final out = s.suggest(
        queryEmbedding: Float32List(5), // wrong dim
        k: 1,
      );
      expect(out, isEmpty);
    });

    test('empty library returns empty', () {
      final s = PresetSuggester(library: PresetEmbeddingLibrary.empty);
      final out = s.suggest(
        queryEmbedding: Float32List(3),
        k: 1,
      );
      expect(out, isEmpty);
    });

    test('k <= 0 returns empty', () {
      final s = PresetSuggester(library: buildLibrary());
      expect(
        s.suggest(
          queryEmbedding: Float32List.fromList([1.0, 0.0, 0.0]),
          k: 0,
        ),
        isEmpty,
      );
      expect(
        s.suggest(
          queryEmbedding: Float32List.fromList([1.0, 0.0, 0.0]),
          k: -1,
        ),
        isEmpty,
      );
    });

    test('tied scores break by preset id alphabetically', () {
      final lib = PresetEmbeddingLibrary.parse('''
        {
          "version": 1, "modelId": "m", "embeddingDim": 2,
          "entries": [
            {"presetId": "z_pres", "embedding": [1.0, 0.0]},
            {"presetId": "a_pres", "embedding": [1.0, 0.0]}
          ]
        }
      ''');
      final s = PresetSuggester(library: lib);
      final out = s.suggest(
        queryEmbedding: Float32List.fromList([1.0, 0.0]),
        k: 2,
      );
      // Equal scores → alphabetical → 'a_pres' first.
      expect(out.map((r) => r.presetId).toList(), ['a_pres', 'z_pres']);
    });
  });

  group('PresetSuggestion value class', () {
    test('equality + hashCode pin presetId + score', () {
      const a = PresetSuggestion(presetId: 'p', score: 0.5);
      const b = PresetSuggestion(presetId: 'p', score: 0.5);
      const c = PresetSuggestion(presetId: 'p', score: 0.4);
      expect(a, b);
      expect(a == c, isFalse);
      expect(a.hashCode, b.hashCode);
    });

    test('toString includes both fields', () {
      const a = PresetSuggestion(presetId: 'p', score: 0.5);
      expect(a.toString(), contains('p'));
      expect(a.toString(), contains('0.5'));
    });
  });

  group('PresetEmbeddingLibrary.empty', () {
    test('is the safe default — no entries, dim 0', () {
      expect(PresetEmbeddingLibrary.empty.entries, isEmpty);
      expect(PresetEmbeddingLibrary.empty.embeddingDim, 0);
      expect(PresetEmbeddingLibrary.empty.modelId, '');
    });
  });
}
