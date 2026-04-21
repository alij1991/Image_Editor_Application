import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:logger/logger.dart';

import '../../core/io/schema_migration.dart';
import 'edit_pipeline.dart';

/// Serializes [EditPipeline]s to and from JSON bytes with:
///
/// - schema version stamping + forward-compat load via [SchemaMigrator]
/// - optional gzip compression for pipelines larger than
///   [_compressThresholdBytes] (per the plan's "compress BLOB > 64KB" rule).
///
/// Used by both the sqflite project store (Phase 12) and the snapshot save
/// paths in the history manager.
class PipelineSerializer {
  PipelineSerializer({Logger? logger}) : _logger = logger ?? Logger();

  final Logger _logger;

  static const int _compressThresholdBytes = 64 * 1024;

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

  /// Encode [pipeline] to UTF-8 bytes. Compresses with gzip if the payload
  /// exceeds [_compressThresholdBytes]; the first byte of the returned
  /// buffer is a magic marker: 0x00 = plain JSON, 0x01 = gzip.
  Uint8List encode(EditPipeline pipeline) {
    final json = pipeline.copyWith(version: currentVersion).toJson();
    final bytes = utf8.encode(jsonEncode(json));
    if (bytes.length < _compressThresholdBytes) {
      return Uint8List.fromList([0x00, ...bytes]);
    }
    final compressed = gzip.encode(bytes);
    _logger.d(
      'PipelineSerializer: compressed '
      '${bytes.length} -> ${compressed.length} bytes',
    );
    return Uint8List.fromList([0x01, ...compressed]);
  }

  /// Decode a buffer previously produced by [encode]. Handles both plain
  /// and gzip-compressed payloads.
  EditPipeline decode(Uint8List bytes) {
    if (bytes.isEmpty) {
      throw const FormatException('PipelineSerializer: empty buffer');
    }
    final marker = bytes.first;
    final payload = bytes.sublist(1);
    final raw = switch (marker) {
      0x00 => utf8.decode(payload),
      0x01 => utf8.decode(gzip.decode(payload)),
      _ => throw FormatException('PipelineSerializer: unknown marker $marker'),
    };
    final json = jsonDecode(raw) as Map<String, dynamic>;
    final migrated = _migrate(json);
    return EditPipeline.fromJson(migrated);
  }

  /// Encode without the marker byte, for contexts that always speak JSON
  /// (tests, debug dumps, the Rust bridge).
  String encodeJsonString(EditPipeline pipeline) {
    final json = pipeline.copyWith(version: currentVersion).toJson();
    return jsonEncode(json);
  }

  /// Decode without the marker byte.
  EditPipeline decodeJsonString(String raw) {
    final json = jsonDecode(raw) as Map<String, dynamic>;
    final migrated = _migrate(json);
    return EditPipeline.fromJson(migrated);
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
