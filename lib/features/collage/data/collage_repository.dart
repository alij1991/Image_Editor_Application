import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../../../core/io/atomic_file.dart';
import '../../../core/io/schema_migration.dart';
import '../../../core/logging/app_logger.dart';
import '../domain/collage_state.dart';

final _log = AppLogger('CollageRepo');

/// On-disk schema version for the collage-state *wrapper*. Bump when
/// the envelope shape changes; add the migration step to [_migrator].
const int _kCollageSchemaVersion = 1;

/// Migration chain for the collage wrapper. v0 is the hypothetical
/// pre-schema shape (bare `CollageState.toJson()` output). The v0 → v1
/// step wraps it into `{schema: 1, state: {...}}` so the first load
/// after this change ships upgrades existing files in-place (there
/// are no shipped v0 files yet, but the seam is ready for the first
/// real bump).
final SchemaMigrator _migrator = SchemaMigrator(
  currentVersion: _kCollageSchemaVersion,
  schemaField: 'schema',
  storeTag: 'CollageRepository',
  migrations: {
    0: (json) => {'state': json},
  },
);

/// Persists a single in-progress [CollageState] so the user can close
/// and re-open the collage route without losing their layout + picks.
///
/// Only one session at a time — the collage page is a single-doc
/// surface. A future multi-doc feature (re-open past collages by name)
/// can extend this to a per-id directory, same as `ScanRepository`.
///
/// File layout: `<AppDocs>/collages/latest.json`. The file is written
/// atomically (see [atomicWriteString]) and carries a `{schema, state}`
/// envelope for forward-compat via [SchemaMigrator].
class CollageRepository {
  CollageRepository({Directory? rootOverride}) : _rootOverride = rootOverride;

  /// Optional root for tests (skips `path_provider`). Production
  /// callers leave this null.
  final Directory? _rootOverride;

  static const String _kFileName = 'latest.json';

  Future<Directory> _root() async {
    final override = _rootOverride;
    if (override != null) {
      if (!override.existsSync()) override.createSync(recursive: true);
      return override;
    }
    final docs = await getApplicationDocumentsDirectory();
    final dir = Directory(p.join(docs.path, 'collages'));
    if (!dir.existsSync()) dir.createSync(recursive: true);
    return dir;
  }

  Future<File> _file() async {
    final root = await _root();
    return File(p.join(root.path, _kFileName));
  }

  /// Persist [state] to disk. Best-effort — IO failures log but don't
  /// throw, so the notifier's debounced auto-save path can fire-and-
  /// forget. The write is atomic (tmp + rename) so a kill mid-flush
  /// leaves the prior saved state intact.
  Future<void> save(CollageState state) async {
    try {
      final envelope = <String, Object?>{
        'schema': _kCollageSchemaVersion,
        'state': state.toJson(),
      };
      final file = await _file();
      await atomicWriteString(file, jsonEncode(envelope));
      _log.d('saved', {'path': file.path, 'cells': state.cells.length});
    } catch (e, st) {
      _log.w('save failed', {'error': e.toString()});
      _log.e('save trace', error: e, stackTrace: st);
    }
  }

  /// Load the persisted collage state, or `null` when nothing's saved,
  /// the file is unreadable, or the migration chain has a gap.
  ///
  /// The [CollageState.fromJson] path validates each saved `imagePath`
  /// against the filesystem and nulls out missing entries, so a
  /// loaded state is always safe to render — broken cells become
  /// empty "Tap to add" slots.
  Future<CollageState?> load() async {
    final file = await _file();
    if (!await file.exists()) return null;
    try {
      final raw = await file.readAsString();
      final decoded = jsonDecode(raw) as Map<String, dynamic>;
      final migrated = _migrator.migrate(decoded);
      if (migrated == null) {
        _log.w('migration gap, dropping', {
          'got': decoded['schema'],
          'expected': _kCollageSchemaVersion,
        });
        return null;
      }
      final stateJson = migrated['state'];
      if (stateJson is! Map<String, dynamic>) {
        _log.w('missing state body after migration');
        return null;
      }
      final state = CollageState.fromJson(stateJson);
      _log.i('loaded', {
        'templateId': state.template.id,
        'cells': state.cells.length,
      });
      return state;
    } catch (e, st) {
      _log.w('load failed', {'error': e.toString(), 'path': file.path});
      _log.e('load trace', error: e, stackTrace: st);
      return null;
    }
  }

  /// Remove the persisted collage. Used by a hypothetical "clear &
  /// start over" action; today no UI calls this but the method exists
  /// so tests can assert post-delete state.
  Future<void> delete() async {
    final file = await _file();
    if (await file.exists()) {
      try {
        await file.delete();
        _log.i('deleted', {'path': file.path});
      } catch (e) {
        _log.w('delete failed', {'error': e.toString()});
      }
    }
  }
}
