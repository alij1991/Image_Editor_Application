import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:logger/logger.dart';

import 'edit_pipeline.dart';

/// Serializes [EditPipeline]s to and from JSON bytes with:
///
/// - schema version stamping + forward-compat load
/// - optional gzip compression for pipelines larger than
///   [_compressThresholdBytes] (per the plan's "compress BLOB > 64KB" rule).
///
/// Used by both the sqflite project store (Phase 12) and the snapshot save
/// paths in the history manager.
class PipelineSerializer {
  PipelineSerializer({Logger? logger}) : _logger = logger ?? Logger();

  final Logger _logger;

  static const int _compressThresholdBytes = 64 * 1024;

  /// Current schema version. Bump whenever the on-disk format changes in a
  /// way that requires explicit migration in [_migrate].
  static const int currentVersion = 1;

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
  /// [currentVersion]. Currently a no-op; versioned migrations are added
  /// here as the schema evolves.
  Map<String, dynamic> _migrate(Map<String, dynamic> json) {
    final v = (json['version'] as num?)?.toInt() ?? 0;
    if (v == currentVersion) return json;
    if (v > currentVersion) {
      _logger.w(
        'PipelineSerializer: future version $v '
        '(currentVersion = $currentVersion) — best-effort parse',
      );
      return json;
    }
    // When we bump the version, add migration steps here. For now, any
    // previous-version document is parsed as-is and will fall through to
    // freezed's fromJson, which may drop unknown fields.
    return json;
  }
}
