import 'dart:convert';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';
import 'package:uuid/uuid.dart';

import '../../core/logging/app_logger.dart';
import '../pipeline/edit_operation.dart';
import '../pipeline/edit_pipeline.dart';
import 'built_in_presets.dart';
import 'preset.dart';

final _log = AppLogger('PresetRepository');

/// Schema statement for the `presets` table at [PresetRepository.currentDbVersion].
///
/// Kept as a top-level const so the onCreate callback and any future
/// migration step that rebuilds the table from scratch can share the
/// same source of truth. Any change to column shape must also land an
/// `ALTER TABLE` (or DROP + CREATE) step in [PresetRepository.runUpgrade].
const String _kPresetsTableSchema = '''
CREATE TABLE IF NOT EXISTS presets (
  id TEXT PRIMARY KEY,
  name TEXT NOT NULL,
  json TEXT NOT NULL,
  created_at INTEGER NOT NULL
)
''';

/// Persistent store for user-defined presets. Built-in presets are
/// provided statically by [BuiltInPresets] and are not stored here.
///
/// Schema:
///   presets(id TEXT PRIMARY KEY, name TEXT, json TEXT, created_at INTEGER)
///
/// Custom presets are serialized as a list of [EditOperation] JSON blobs
/// so the same schema survives forward-compat pipeline changes.
class PresetRepository {
  PresetRepository({String? dbPathOverride})
      : _dbPathOverride = dbPathOverride;

  /// Optional absolute path for the sqflite database file — skips the
  /// `path_provider` lookup so tests can drive the store against a
  /// temp directory without platform channels. Production code passes
  /// nothing.
  final String? _dbPathOverride;

  Database? _db;
  bool _disposed = false;

  /// Sqflite schema version for the `presets` table. Bump when the
  /// table shape changes; add the CREATE/ALTER statements to
  /// [runUpgrade] so pre-bump databases auto-upgrade on open.
  ///
  /// Public so the schema-migration test can pin the "current shipped
  /// version" without duplicating the literal — a drift between the
  /// test's expected version and the code would otherwise go
  /// unnoticed.
  static const int currentDbVersion = 1;

  Future<Database> _openDb() async {
    if (_db != null) return _db!;
    try {
      final dbPath = _dbPathOverride ??
          p.join(
            (await getApplicationDocumentsDirectory()).path,
            'presets.db',
          );
      _log.d('openDb', {'path': dbPath});
      _db = await openDatabase(
        dbPath,
        version: currentDbVersion,
        onCreate: (db, version) async {
          await db.execute(_kPresetsTableSchema);
        },
        onUpgrade: runUpgrade,
      );
      _log.i('db ready');
      return _db!;
    } catch (e, st) {
      _log.e('openDb failed', error: e, stackTrace: st);
      rethrow;
    }
  }

  /// Sqflite migration hook. Called once per `openDatabase` when the
  /// on-disk version is lower than [currentDbVersion]. Currently a
  /// no-op beyond logging because we've never shipped a v2 table — but
  /// even a no-op registered handler is load-bearing: without it, a
  /// future bump would crash at open with
  /// `DatabaseException(Database version is newer than…)`.
  ///
  /// Add future migrations as `if (oldVersion < 2) await db.execute(…);`
  /// blocks below. Each block is independent, so a user on v0 who
  /// upgrades past multiple releases walks the chain in order.
  ///
  /// Exposed publicly (with [visibleForTesting]) so the synthetic
  /// v1 → v2 schema test can wire this exact handler into a bumped
  /// `openDatabase` call and confirm the seam fires without crashing.
  @visibleForTesting
  static Future<void> runUpgrade(
    Database db,
    int oldVersion,
    int newVersion,
  ) async {
    _log.i('upgrade', {'from': oldVersion, 'to': newVersion});
    // When the table schema changes, add migration steps here. The
    // `json` column's blob content is already versioned by Preset's
    // own Freezed serializer (additive fields are tolerated on load).
  }

  /// Return built-in + custom presets in that order.
  Future<List<Preset>> loadAll() async {
    final builtIn = BuiltInPresets.all;
    List<Preset> custom = const [];
    try {
      custom = await loadCustom();
    } catch (e) {
      _log.w('custom presets unavailable', {'error': e.toString()});
    }
    _log.i('loadAll', {'builtIn': builtIn.length, 'custom': custom.length});
    return [...builtIn, ...custom];
  }

  Future<List<Preset>> loadCustom() async {
    final db = await _openDb();
    final rows =
        await db.query('presets', orderBy: 'created_at DESC');
    return rows.map(_rowToPreset).toList(growable: false);
  }

  Future<Preset> saveFromPipeline({
    required String name,
    required EditPipeline pipeline,
  }) async {
    final db = await _openDb();
    final preset = Preset(
      id: const Uuid().v4(),
      name: name,
      operations: pipeline.operations.where((o) => o.enabled).toList(),
      category: 'Custom',
    );
    final json = jsonEncode(preset.toJson());
    await db.insert(
      'presets',
      {
        'id': preset.id,
        'name': preset.name,
        'json': json,
        'created_at': DateTime.now().millisecondsSinceEpoch,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
    _log.i('saveFromPipeline', {
      'id': preset.id,
      'name': name,
      'ops': preset.operations.length,
    });
    return preset;
  }

  Future<void> delete(String id) async {
    final db = await _openDb();
    await db.delete('presets', where: 'id = ?', whereArgs: [id]);
    _log.i('delete', {'id': id});
  }

  Preset _rowToPreset(Map<String, Object?> row) {
    final raw = row['json'] as String;
    final json = jsonDecode(raw) as Map<String, dynamic>;
    final opsRaw = (json['operations'] as List?) ?? const [];
    final operations = opsRaw
        .map((e) => EditOperation.fromJson(e as Map<String, dynamic>))
        .toList(growable: false);
    return Preset(
      id: row['id'] as String,
      name: row['name'] as String,
      operations: operations,
      category: 'Custom',
    );
  }

  Future<void> close() async {
    if (_disposed) return;
    _disposed = true;
    await _db?.close();
    _db = null;
  }
}
