/// XVI.96 (B2) — Loader for the synthetic test corpus.
///
/// Reads `assets/test_images/manifest.json` via `rootBundle` and
/// returns a list of [TestImage]s. The lab UI calls this once on
/// page open; the matrix runner calls it once per CI invocation.
///
/// The loader does NOT decode the image bytes — that's deferred to
/// the per-op runner so the lab can lazily decode only the images it
/// actually needs for the chosen op.
library;

import 'dart:convert';

import 'package:flutter/services.dart';

import 'test_image.dart';

/// Path to the manifest. Kept as a constant so the loader is
/// trivially testable with a `bundle.load` mock.
const String kTestCorpusManifestPath = 'assets/test_images/manifest.json';

/// Parsed test corpus: version, generation metadata, image list.
class TestCorpus {
  TestCorpus({
    required this.version,
    required this.generatedBy,
    required this.seed,
    required this.notes,
    required this.images,
  });

  /// Manifest schema version. Caller validates against the expected
  /// constant ([kSupportedManifestVersion]).
  final int version;

  /// Path to the script that produced the manifest. Recorded so
  /// `Lab:` trailers can cite reproducibility info.
  final String generatedBy;

  /// RNG seed used by the generator. Anyone re-running the script
  /// with the same seed reproduces bit-identical assets.
  final int seed;

  /// Free-form note carried from the manifest header.
  final String notes;

  /// Catalogue of test images.
  final List<TestImage> images;

  /// Schema version the loader expects. Bumped when adding required
  /// fields or breaking JSON layout.
  static const int kSupportedManifestVersion = 1;

  /// Load + parse the corpus from `assetBundle`. Defaults to
  /// `rootBundle`. Pass a custom bundle in tests to avoid touching
  /// disk.
  static Future<TestCorpus> load({AssetBundle? assetBundle}) async {
    final bundle = assetBundle ?? rootBundle;
    final raw = await bundle.loadString(kTestCorpusManifestPath);
    return fromJsonString(raw);
  }

  /// Parse a JSON string into a [TestCorpus]. Pure — no IO.
  static TestCorpus fromJsonString(String raw) {
    final decoded = jsonDecode(raw);
    if (decoded is! Map<String, Object?>) {
      throw FormatException(
        'TestCorpus: manifest root must be an object, got '
        '${decoded.runtimeType}',
      );
    }
    final version = decoded['version'];
    if (version is! int) {
      throw FormatException(
        'TestCorpus: "version" must be an int, got $version',
      );
    }
    if (version != kSupportedManifestVersion) {
      throw FormatException(
        'TestCorpus: manifest version $version not supported by '
        'loader version $kSupportedManifestVersion. Regenerate the '
        'corpus with scripts/generate_test_corpus.py.',
      );
    }
    final imagesRaw = decoded['images'];
    if (imagesRaw is! List) {
      throw FormatException(
        'TestCorpus: "images" must be a list, got $imagesRaw',
      );
    }
    final images = imagesRaw
        .map((e) => TestImage.fromManifest(e as Map<String, Object?>))
        .toList(growable: false);
    return TestCorpus(
      version: version,
      generatedBy: (decoded['generatedBy'] as String?) ?? '',
      seed: (decoded['seed'] as int?) ?? 0,
      notes: (decoded['notes'] as String?) ?? '',
      images: images,
    );
  }

  /// Look up an image by [id]. Throws [StateError] if not found.
  TestImage byId(String id) {
    for (final img in images) {
      if (img.id == id) return img;
    }
    throw StateError('TestCorpus: no image with id "$id"');
  }

  /// All images that declare [opId] in `expectedOps`.
  List<TestImage> imagesFor(String opId) {
    return images
        .where((img) => img.expectedOps.contains(opId))
        .toList(growable: false);
  }
}
