import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';

import '../../core/logging/app_logger.dart';
import 'model_descriptor.dart';

final _log = AppLogger('ModelCache');

/// Row in the model cache — tracks a single downloaded model file.
class ModelCacheEntry {
  const ModelCacheEntry({
    required this.modelId,
    required this.version,
    required this.path,
    required this.sizeBytes,
    required this.sha256,
    required this.downloadedAt,
  });

  final String modelId;
  final String version;
  final String path;
  final int sizeBytes;
  final String sha256;
  final DateTime downloadedAt;

  bool get fileExistsSync => File(path).existsSync();

  Future<bool> get fileExists async => File(path).exists();

  Map<String, Object?> toRow() => {
        'id': modelId,
        'version': version,
        'path': path,
        'size_bytes': sizeBytes,
        'sha256': sha256,
        'downloaded_at': downloadedAt.millisecondsSinceEpoch,
      };

  static ModelCacheEntry fromRow(Map<String, Object?> row) => ModelCacheEntry(
        modelId: row['id'] as String,
        version: row['version'] as String,
        path: row['path'] as String,
        sizeBytes: row['size_bytes'] as int,
        sha256: row['sha256'] as String,
        downloadedAt: DateTime.fromMillisecondsSinceEpoch(
          row['downloaded_at'] as int,
        ),
      );
}

/// sqflite-indexed disk cache of downloaded model files.
///
/// Keeps one row per downloaded model. Provides:
///   - `get` / `put` / `delete` for individual entries
///   - `loadAll` for the Model Manager UI
///   - `evict` to remove the oldest entries when over budget
///   - `destinationPath` for downloaders — a stable per-model path
///     inside the app documents directory
///
/// The cache directory is lazily created under
/// `ApplicationDocumentsDirectory/models/`.
class ModelCache {
  ModelCache();

  Database? _db;
  Directory? _modelsDir;

  Future<Database> _openDb() async {
    if (_db != null) return _db!;
    final docs = await getApplicationDocumentsDirectory();
    _modelsDir = Directory(p.join(docs.path, 'models'));
    await _modelsDir!.create(recursive: true);
    final dbPath = p.join(docs.path, 'model_cache.db');
    _log.d('openDb', {'path': dbPath, 'modelsDir': _modelsDir!.path});
    _db = await openDatabase(
      dbPath,
      version: 1,
      onCreate: (db, v) async {
        await db.execute('''
          CREATE TABLE IF NOT EXISTS models (
            id TEXT PRIMARY KEY,
            version TEXT NOT NULL,
            path TEXT NOT NULL,
            size_bytes INTEGER NOT NULL,
            sha256 TEXT NOT NULL,
            downloaded_at INTEGER NOT NULL
          )
        ''');
      },
    );
    _log.i('ready');
    return _db!;
  }

  /// Compute the destination path for [descriptor] inside the models
  /// directory. Creates the parent folder if needed. Works even when
  /// the sqflite index doesn't have a row yet (i.e. first download).
  Future<String> destinationPathFor(ModelDescriptor descriptor) async {
    await _openDb();
    final dir = _modelsDir!;
    final filename = '${descriptor.id}_${descriptor.version}';
    return p.join(dir.path, filename);
  }

  /// Look up an entry by model id. Returns null if not cached OR if
  /// the file is missing on disk (i.e. user cleared the cache out of
  /// band).
  Future<ModelCacheEntry?> get(String modelId) async {
    final db = await _openDb();
    final rows = await db.query(
      'models',
      where: 'id = ?',
      whereArgs: [modelId],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    final entry = ModelCacheEntry.fromRow(rows.first);
    if (!(await entry.fileExists)) {
      _log.w('file missing; evicting stale row', {'id': modelId});
      await db.delete('models', where: 'id = ?', whereArgs: [modelId]);
      return null;
    }
    return entry;
  }

  /// Insert or replace an entry after a successful download.
  Future<void> put(ModelCacheEntry entry) async {
    final db = await _openDb();
    await db.insert(
      'models',
      entry.toRow(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
    _log.i('put', {
      'id': entry.modelId,
      'version': entry.version,
      'sizeBytes': entry.sizeBytes,
    });
  }

  /// Delete an entry and its file on disk.
  Future<void> delete(String modelId) async {
    final entry = await get(modelId);
    final db = await _openDb();
    if (entry != null) {
      try {
        await File(entry.path).delete();
      } catch (e) {
        _log.w('file delete failed', {'id': modelId, 'error': e.toString()});
      }
    }
    await db.delete('models', where: 'id = ?', whereArgs: [modelId]);
    _log.i('delete', {'id': modelId});
  }

  /// Every cached entry. Used by the Model Manager UI.
  Future<List<ModelCacheEntry>> loadAll() async {
    final db = await _openDb();
    final rows = await db.query('models', orderBy: 'downloaded_at DESC');
    return rows.map(ModelCacheEntry.fromRow).toList(growable: false);
  }

  /// Total bytes currently used by downloaded models.
  Future<int> totalBytes() async {
    final entries = await loadAll();
    return entries.fold<int>(0, (sum, e) => sum + e.sizeBytes);
  }

  /// Evict the least-recently-downloaded entries until total disk
  /// usage is under [maxBytes]. Returns the number of entries removed.
  Future<int> evictUntilUnder(int maxBytes) async {
    final entries = await loadAll();
    int total = entries.fold<int>(0, (sum, e) => sum + e.sizeBytes);
    if (total <= maxBytes) return 0;
    // Sort oldest first.
    final oldest = [...entries]
      ..sort((a, b) => a.downloadedAt.compareTo(b.downloadedAt));
    int removed = 0;
    for (final e in oldest) {
      if (total <= maxBytes) break;
      await delete(e.modelId);
      total -= e.sizeBytes;
      removed++;
    }
    _log.i('evictUntilUnder', {'maxBytes': maxBytes, 'removed': removed});
    return removed;
  }

  Future<void> close() async {
    await _db?.close();
    _db = null;
  }
}
