import 'dart:convert';
import 'dart:typed_data';

import 'package:logger/logger.dart';

import '../../core/io/compressed_json.dart';
import '../../core/io/schema_migration.dart';
import 'edit_pipeline.dart';

/// Serializes [EditPipeline]s to and from JSON bytes with:
///
/// - schema version stamping + forward-compat load via [SchemaMigrator]
/// - optional gzip compression for pipelines at or above the
///   [kCompressedJsonGzipThreshold] (per the plan's "compress BLOB
///   > 64 KB" rule).
///
/// Used by:
/// - the snapshot save paths in the history manager,
/// - [ProjectStore] for auto-save envelopes (via [decodeFromMap] — the
///   envelope's pipeline sub-map hands the migration seam off without a
///   redundant JSON roundtrip).
class PipelineSerializer {
  PipelineSerializer({Logger? logger}) : _logger = logger ?? Logger();

  final Logger _logger;

  /// Current schema version. Bump whenever the on-disk format changes in
  /// a way that requires explicit migration. Add a migration step to
  /// [_migrator] at the previous version for every bump.
  static const int currentVersion = 1;

  /// The migration pipeline. One entry per historical version, keyed by
  /// `fromVersion`. The v0 → v1 step is currently a no-op that just
  /// stamps the version field (pre-schema pipelines had no `version`
  /// key; the migrator auto-treats a missing field as v0 and the step
  /// below carries the payload forward untouched).
  static final SchemaMigrator _migrator = SchemaMigrator(
    currentVersion: currentVersion,
    schemaField: 'version',
    storeTag: 'PipelineSerializer',
    migrations: {
      // v0 (pre-schema) → v1: identity carry; the migrator stamps
      // `version: 1` after the last step.
      0: (json) => json,
    },
  );

  /// Encode [pipeline] to UTF-8 bytes. Delegates framing (marker byte +
  /// optional gzip) to [encodeCompressedJson].
  Uint8List encode(EditPipeline pipeline) {
    return encodeCompressedJson(encodeJsonString(pipeline));
  }

  /// Decode a buffer previously produced by [encode]. Handles both
  /// plain and gzip-compressed payloads via [decodeCompressedJson].
  EditPipeline decode(Uint8List bytes) {
    return decodeJsonString(decodeCompressedJson(bytes));
  }

  /// Encode without the marker byte, for contexts that always speak JSON
  /// (tests, debug dumps, the Rust bridge).
  String encodeJsonString(EditPipeline pipeline) {
    final json = pipeline.copyWith(version: currentVersion).toJson();
    return jsonEncode(json);
  }

  /// Decode a JSON string previously produced by [encodeJsonString].
  /// Goes through the same [_migrate] seam as [decode] / [decodeFromMap].
  EditPipeline decodeJsonString(String raw) {
    final json = jsonDecode(raw) as Map<String, dynamic>;
    return decodeFromMap(json);
  }

  /// Decode a pipeline from an already-parsed JSON map. Runs the
  /// [_migrate] seam before handing off to [EditPipeline.fromJson].
  ///
  /// Used by [ProjectStore.load] where the pipeline arrives nested
  /// inside a wrapper envelope that the caller has already parsed — a
  /// JSON-encode-then-decode roundtrip through [decodeJsonString]
  /// would be wasted work. Consolidating on this entry point is what
  /// lets Phase IV.2 retire the inline `EditPipeline.fromJson` call
  /// in [ProjectStore].
  EditPipeline decodeFromMap(Map<String, dynamic> json) {
    return EditPipeline.fromJson(_migrate(json));
  }

  /// Apply any schema migrations needed to bring [json] up to
  /// [currentVersion]. Delegates to the shared [SchemaMigrator].
  ///
  /// When the migrator returns `null` (incomplete chain), we fall back
  /// to the input as-is rather than throwing — a partial migration is
  /// still more useful than a hard failure, and Freezed's `fromJson`
  /// tolerates missing fields.
  Map<String, dynamic> _migrate(Map<String, dynamic> json) {
    final migrated = _migrator.migrate(json);
    if (migrated == null) {
      _logger.w(
        'PipelineSerializer: migration chain incomplete, '
        'falling through to fromJson with the original payload',
      );
      return json;
    }
    return migrated;
  }
}
