import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

/// Phase XVI.58 — pure-Dart kNN over a library of pre-baked preset
/// embeddings. The embedding dimension is opaque (whatever the
/// encoder ships); the suggester just compares cosine similarity
/// between the source image's embedding (from
/// [PresetEmbedderService.embedFromPath]) and each library entry.
///
/// Both sides are assumed L2-normalised, so cosine similarity
/// collapses to a dot product. The library JSON is intended to be
/// pre-baked offline by a one-shot script that runs the encoder
/// over each built-in preset's representative reference image.
///
/// File format (`assets/presets/preset_embeddings.json`):
///
/// ```json
/// {
///   "version": 1,
///   "modelId": "mobilevit_v2_0_5_int8",
///   "embeddingDim": 256,
///   "entries": [
///     {"presetId": "wb_neutral", "embedding": [0.012, -0.043, ...]},
///     ...
///   ]
/// }
/// ```
///
/// `version` + `modelId` let us refuse to suggest when the embedder
/// in use disagrees with the library — better to silently no-op
/// than to return nonsense suggestions.
class PresetSuggester {
  PresetSuggester({required this.library});

  final PresetEmbeddingLibrary library;

  /// Top-[k] preset ids by cosine similarity to [queryEmbedding].
  /// Returns presets sorted by similarity DESCENDING. When the
  /// query and library disagree on dimensions, returns an empty
  /// list (silent fallback per project convention).
  List<PresetSuggestion> suggest({
    required Float32List queryEmbedding,
    int k = 5,
    double minSimilarity = 0.0,
  }) {
    if (queryEmbedding.length != library.embeddingDim) return const [];
    if (library.entries.isEmpty || k <= 0) return const [];

    final results = <PresetSuggestion>[];
    for (final entry in library.entries) {
      final score = _cosine(queryEmbedding, entry.embedding);
      if (score < minSimilarity) continue;
      results.add(PresetSuggestion(presetId: entry.presetId, score: score));
    }
    // Sort descending by score, stable on tie via name.
    results.sort((a, b) {
      final cmp = b.score.compareTo(a.score);
      if (cmp != 0) return cmp;
      return a.presetId.compareTo(b.presetId);
    });
    if (results.length <= k) return results;
    return results.sublist(0, k);
  }

  /// Cosine similarity between two L2-normalised vectors. Falls back
  /// to the full cosine formula when either side is unnormalised
  /// (defensive — pre-baked libraries should be normalised at bake
  /// time, but the runtime check costs us nothing).
  static double _cosine(Float32List a, Float32List b) {
    if (a.length != b.length) return 0.0;
    double dot = 0;
    double aSq = 0;
    double bSq = 0;
    for (var i = 0; i < a.length; i++) {
      dot += a[i] * b[i];
      aSq += a[i] * a[i];
      bSq += b[i] * b[i];
    }
    if (aSq <= 0 || bSq <= 0) return 0;
    // If both are already L2-normalised, aSq * bSq ≈ 1, and this
    // collapses to the dot product. Keeping the divide handles
    // unnormalised libraries gracefully.
    return dot / (math.sqrt(aSq) * math.sqrt(bSq));
  }
}

/// One result row from [PresetSuggester.suggest].
class PresetSuggestion {
  const PresetSuggestion({required this.presetId, required this.score});
  final String presetId;
  final double score;

  @override
  bool operator ==(Object other) =>
      other is PresetSuggestion &&
      other.presetId == presetId &&
      other.score == score;

  @override
  int get hashCode => Object.hash(presetId, score);

  @override
  String toString() => 'PresetSuggestion($presetId, score=$score)';
}

/// One library row — a preset id paired with its baked embedding.
class PresetEmbeddingEntry {
  const PresetEmbeddingEntry({
    required this.presetId,
    required this.embedding,
  });
  final String presetId;
  final Float32List embedding;
}

/// Parsed `preset_embeddings.json` payload.
class PresetEmbeddingLibrary {
  const PresetEmbeddingLibrary({
    required this.version,
    required this.modelId,
    required this.embeddingDim,
    required this.entries,
  });

  final int version;
  final String modelId;
  final int embeddingDim;
  final List<PresetEmbeddingEntry> entries;

  /// Empty library — used as a safe default when the JSON file is
  /// missing. Suggester returns an empty list against an empty
  /// library; the "For You" rail then quietly disappears.
  static const empty = PresetEmbeddingLibrary(
    version: 0,
    modelId: '',
    embeddingDim: 0,
    entries: <PresetEmbeddingEntry>[],
  );

  /// Parse a JSON string into a library. Throws [FormatException]
  /// when the payload is malformed; returns [empty] for null /
  /// empty / blank input so the caller can `?? empty` gracefully.
  static PresetEmbeddingLibrary parse(String? jsonStr) {
    if (jsonStr == null || jsonStr.trim().isEmpty) return empty;
    final raw = json.decode(jsonStr);
    if (raw is! Map<String, dynamic>) {
      throw const FormatException('Library root must be a JSON object');
    }
    final version = raw['version'];
    final modelId = raw['modelId'];
    final embeddingDim = raw['embeddingDim'];
    final entriesRaw = raw['entries'];
    if (version is! int || version <= 0) {
      throw const FormatException('Library version must be a positive int');
    }
    if (modelId is! String || modelId.isEmpty) {
      throw const FormatException('Library modelId must be a non-empty string');
    }
    if (embeddingDim is! int || embeddingDim <= 0) {
      throw const FormatException(
          'Library embeddingDim must be a positive int');
    }
    if (entriesRaw is! List) {
      throw const FormatException('Library entries must be a JSON array');
    }
    final entries = <PresetEmbeddingEntry>[];
    for (final e in entriesRaw) {
      if (e is! Map<String, dynamic>) {
        throw const FormatException('Each entry must be a JSON object');
      }
      final presetId = e['presetId'];
      final embedding = e['embedding'];
      if (presetId is! String || presetId.isEmpty) {
        throw const FormatException(
          'Entry presetId must be a non-empty string',
        );
      }
      if (embedding is! List) {
        throw const FormatException('Entry embedding must be a JSON array');
      }
      if (embedding.length != embeddingDim) {
        throw FormatException(
          'Entry "$presetId" has length ${embedding.length}, expected '
          '$embeddingDim',
        );
      }
      final vec = Float32List(embeddingDim);
      for (var i = 0; i < embeddingDim; i++) {
        final v = embedding[i];
        if (v is! num) {
          throw FormatException(
            'Entry "$presetId" has non-numeric value at index $i',
          );
        }
        vec[i] = v.toDouble();
      }
      entries.add(PresetEmbeddingEntry(presetId: presetId, embedding: vec));
    }
    return PresetEmbeddingLibrary(
      version: version,
      modelId: modelId,
      embeddingDim: embeddingDim,
      entries: entries,
    );
  }
}

