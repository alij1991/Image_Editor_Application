import 'dart:convert';

import 'package:flutter/services.dart';

import '../../core/logging/app_logger.dart';
import 'model_descriptor.dart';

final _log = AppLogger('ModelManifest');

/// Loads and parses `assets/models/manifest.json` into a typed list of
/// [ModelDescriptor]s. The manifest is the single source of truth for
/// every on-device model the app ships or downloads.
///
/// The bundled manifest is shipped as a Flutter asset, so loading is
/// async only because of `rootBundle.loadString`; parsing is purely
/// synchronous after that.
class ModelManifest {
  ModelManifest(this.descriptors);

  final List<ModelDescriptor> descriptors;

  /// Look up a descriptor by its canonical id (e.g. `lama_inpaint`,
  /// `selfie_segmenter`). Returns null if the id is not in the manifest.
  ModelDescriptor? byId(String id) {
    for (final d in descriptors) {
      if (d.id == id) return d;
    }
    return null;
  }

  /// All bundled (no-download) descriptors.
  Iterable<ModelDescriptor> get bundled =>
      descriptors.where((d) => d.bundled);

  /// All descriptors that require a download on first use.
  Iterable<ModelDescriptor> get downloadable =>
      descriptors.where((d) => !d.bundled);

  /// Load the manifest from the app's asset bundle. Tolerates missing
  /// or malformed JSON by logging and returning an empty manifest so
  /// the app still starts.
  static Future<ModelManifest> loadFromAssets({
    String assetKey = 'assets/models/manifest.json',
  }) async {
    try {
      final raw = await rootBundle.loadString(assetKey);
      final manifest = parse(raw);
      _log.i('loaded', {
        'count': manifest.descriptors.length,
        'bundled': manifest.bundled.length,
        'downloadable': manifest.downloadable.length,
      });
      return manifest;
    } catch (e, st) {
      _log.e('load failed', error: e, stackTrace: st);
      return ModelManifest(const []);
    }
  }

  /// Parse a JSON string into a typed manifest. Exposed for tests and
  /// the asset loader above.
  static ModelManifest parse(String rawJson) {
    final json = jsonDecode(rawJson) as Map<String, dynamic>;
    final rawModels = (json['models'] as List?) ?? const [];
    final descriptors = <ModelDescriptor>[];
    for (final raw in rawModels) {
      if (raw is! Map<String, dynamic>) continue;
      if (_isMetadataOnly(raw)) {
        _log.d('skipping metadata-only entry', {'id': raw['id']});
        continue;
      }
      try {
        descriptors.add(_parseDescriptor(raw));
      } catch (e) {
        _log.w('skipping invalid descriptor',
            {'id': raw['id'], 'error': e.toString()});
      }
    }
    return ModelManifest(List.unmodifiable(descriptors));
  }

  /// Whether a raw manifest entry should be excluded from [descriptors].
  ///
  /// `"metadataOnly": true` is used for models that are managed by an
  /// external SDK (e.g. ML Kit for `selfie_segmenter` and
  /// `face_detection_short`). The entry documents which model the SDK
  /// uses, but the app never loads it via [ModelRegistry] — so it must
  /// not appear in the descriptor list or the Model Manager UI.
  static bool _isMetadataOnly(Map<String, dynamic> raw) =>
      raw['metadataOnly'] == true;

  static ModelDescriptor _parseDescriptor(Map<String, dynamic> raw) {
    // Use freezed's generated fromJson on a normalized map. The raw
    // manifest uses `sizeBytes`, `runtime`, etc.; we translate any
    // field-renaming quirks here before handing off.
    final runtimeStr = raw['runtime'] as String?;
    if (runtimeStr == null) {
      throw ArgumentError('missing runtime for ${raw['id']}');
    }
    // The ModelDescriptor freezed class uses snake_case field names
    // via json_serializable (see build.yaml: field_rename: snake).
    // Re-key the raw camelCase fields so fromJson picks them up.
    final normalized = <String, dynamic>{
      'id': raw['id'],
      'version': raw['version'],
      'runtime': runtimeStr,
      'size_bytes': raw['sizeBytes'],
      'sha256': raw['sha256'],
      'bundled': raw['bundled'],
      if (raw['assetPath'] != null) 'asset_path': raw['assetPath'],
      if (raw['url'] != null) 'url': raw['url'],
      'purpose': raw['purpose'] ?? '',
    };
    return ModelDescriptor.fromJson(normalized);
  }
}
