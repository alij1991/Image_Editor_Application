import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:image_editor/ai/services/preset_suggest/preset_embedder_service.dart';
import 'package:image_editor/ai/services/preset_suggest/preset_suggester.dart';

/// Phase XVI.66c — integrity guards for the baked
/// `assets/presets/preset_embeddings.json` library.
///
/// The bake step (`scripts/bake_preset_embeddings/bake.py`) is run
/// offline, so the only thing keeping the runtime + asset in sync
/// is the schema check below + the model-id agreement. If the bake
/// drifts (different MobileViT-v2 export, different schema version,
/// missing presets), these tests fail loudly so we don't ship a
/// silent "For You rail surfaces nothing" regression.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('preset_embeddings.json — runtime shape', () {
    late PresetEmbeddingLibrary library;

    setUpAll(() async {
      final raw = await rootBundle.loadString(
        'assets/presets/preset_embeddings.json',
      );
      library = PresetEmbeddingLibrary.parse(raw);
    });

    test('library version is 1', () {
      expect(library.version, 1);
    });

    test('library modelId matches kPresetEmbedderModelId', () {
      expect(
        library.modelId,
        kPresetEmbedderModelId,
        reason:
            'baked modelId must match the runtime embedder constant — if you '
            'rebake against a different model, update kPresetEmbedderModelId '
            'AND this test together.',
      );
    });

    test('library exposes a positive embedding dimension', () {
      expect(library.embeddingDim, greaterThan(0));
    });

    test('library has every built-in preset id', () {
      // The bake script reads built_in_presets.dart; if it parses N
      // presets it should produce N entries. Anything less means the
      // regex skipped a literal — we want that to surface here.
      expect(library.entries.length, greaterThanOrEqualTo(28),
          reason:
              'expected ≥ 28 baked presets (one per built-in literal). Re-run '
              'scripts/bake_preset_embeddings/bake.py after editing built_in_presets.dart.');
    });

    test('every entry is L2-normalised within 1e-3', () {
      for (final entry in library.entries) {
        var sumSq = 0.0;
        for (final v in entry.embedding) {
          sumSq += v * v;
        }
        // Allow a slight tolerance for FP32 round-trip through JSON.
        expect(
          sumSq,
          closeTo(1.0, 1e-3),
          reason: '${entry.presetId} embedding norm² is $sumSq — bake step '
              'should L2-normalise before writing.',
        );
      }
    });

    test('preset ids are unique across the library', () {
      final ids = library.entries.map((e) => e.presetId).toList();
      final unique = ids.toSet();
      expect(ids.length, unique.length,
          reason: 'duplicate presetId in baked library: $ids');
    });

    test('a real query embedding produces a deterministic top-k', () {
      // Build a vector identical to the first library entry; the
      // suggester should rank score-1.0 hits first (multiple presets
      // can tie at 1.0 because the bake assigns one embedding per
      // category, so every preset in the same category as
      // `library.entries.first` ends up with score == 1).
      final library0 = library.entries.first;
      final suggester = PresetSuggester(library: library);
      final query = library0.embedding;
      final results = suggester.suggest(queryEmbedding: query, k: 3);
      expect(results, isNotEmpty);
      expect(results.first.score, closeTo(1.0, 1e-4),
          reason: 'self-similarity must be ~1');
      expect(results.length, lessThanOrEqualTo(3));
      // The exact ordering inside the score-1.0 tie is alphabetical
      // by presetId per PresetSuggester's tie-break rule, so just
      // verify the queried preset appears somewhere in the rail.
      final ids = results.map((r) => r.presetId).toSet();
      expect(ids, contains(library0.presetId));
    });
  });
}
