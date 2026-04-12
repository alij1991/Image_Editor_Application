import 'dart:convert';

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

/// Persistent store for user-defined presets. Built-in presets are
/// provided statically by [BuiltInPresets] and are not stored here.
///
/// Schema:
///   presets(id TEXT PRIMARY KEY, name TEXT, json TEXT, created_at INTEGER)
///
/// Custom presets are serialized as a list of [EditOperation] JSON blobs
/// so the same schema survives forward-compat pipeline changes.
class PresetRepository {
  PresetRepository();

  Database? _db;
  bool _disposed = false;

  Future<Database> _openDb() async {
    if (_db != null) return _db!;
    try {
      final docs = await getApplicationDocumentsDirectory();
      final path = p.join(docs.path, 'presets.db');
      _log.d('openDb', {'path': path});
      _db = await openDatabase(
        path,
        version: 1,
        onCreate: (db, version) async {
          await db.execute('''
            CREATE TABLE IF NOT EXISTS presets (
              id TEXT PRIMARY KEY,
              name TEXT NOT NULL,
              json TEXT NOT NULL,
              created_at INTEGER NOT NULL
            )
          ''');
        },
      );
      _log.i('db ready');
      return _db!;
    } catch (e, st) {
      _log.e('openDb failed', error: e, stackTrace: st);
      rethrow;
    }
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
