import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../../../core/io/atomic_file.dart';
import '../../../core/io/schema_migration.dart';
import '../../../core/logging/app_logger.dart';
import '../domain/models/scan_models.dart';

final _log = AppLogger('ScanRepo');

/// On-disk schema version for the scan-session *wrapper*. The wrapper
/// was introduced in v1; files written before then (v0) are the raw
/// `ScanSession.toJson()` shape and are migrated into the wrapper
/// on first read.
const int _kScanSchemaVersion = 1;

/// VIII.16 — maximum number of undo-stack entries persisted alongside
/// a session. Each entry is a full session snapshot, so 5 keeps the
/// JSON small (typical session ≈ 200 KB → ≈ 1 MB total).
const int kPersistedUndoDepth = 5;

/// Migration chain for the scan wrapper. The v0 → v1 step wraps a
/// bare session map into `{schema: 1, session: {...}}` so existing
/// on-disk files auto-upgrade the first time they're loaded after
/// the schema-versioning change shipped.
final SchemaMigrator _migrator = SchemaMigrator(
  currentVersion: _kScanSchemaVersion,
  schemaField: 'schema',
  storeTag: 'ScanRepository',
  migrations: {
    0: (json) => {'session': json},
  },
);

/// Flat-file persistence for scan sessions. Each session is written as
/// a JSON file under `<appDocs>/scans/<sessionId>.json`. We also copy
/// the processed page JPEGs into `<appDocs>/scans/<sessionId>/` so they
/// survive temp-dir eviction.
///
/// Format (v1): `{"schema": 1, "session": {ScanSession.toJson()}}`.
/// Pre-v1 files without the wrapper are auto-migrated on load.
class ScanRepository {
  ScanRepository({Directory? rootOverride}) : _rootOverride = rootOverride;

  /// Optional root for tests (skips `path_provider`, which isn't
  /// available in pure `flutter_test` runs). Production callers leave
  /// this null — [_root] resolves `<AppDocs>/scans/` on demand.
  final Directory? _rootOverride;

  Future<Directory> _root() async {
    final override = _rootOverride;
    if (override != null) {
      if (!override.existsSync()) override.createSync(recursive: true);
      return override;
    }
    final docs = await getApplicationDocumentsDirectory();
    final dir = Directory(p.join(docs.path, 'scans'));
    if (!dir.existsSync()) dir.createSync(recursive: true);
    return dir;
  }

  /// Persist a finished session. Pages with processed JPEGs are copied
  /// into a session-specific folder so future launches can still load
  /// them after the OS clears the temp cache.
  ///
  /// VIII.16 — when [undoStack] is non-empty, the truncated tail (last
  /// [kPersistedUndoDepth] entries — bounded so the saved file stays
  /// small) is persisted alongside the session so re-opening from
  /// History restores undo capability instead of starting with an
  /// empty stack.
  Future<void> save(
    ScanSession session, {
    List<ScanSession> undoStack = const [],
  }) async {
    final root = await _root();
    final sessionDir = Directory(p.join(root.path, session.id));
    if (!sessionDir.existsSync()) sessionDir.createSync(recursive: true);

    // Copy processed images to durable storage and rewrite paths.
    final pages = <ScanPage>[];
    for (final page in session.pages) {
      final source = page.processedImagePath ?? page.rawImagePath;
      final dest = p.join(sessionDir.path, '${page.id}.jpg');
      try {
        await File(source).copy(dest);
        pages.add(page.copyWith(processedImagePath: dest));
      } catch (e) {
        _log.w('copy page failed', {'page': page.id, 'err': e.toString()});
        pages.add(page);
      }
    }

    final stored = session.copyWith(pages: pages);
    final file = File(p.join(root.path, '${session.id}.json'));
    // Wrap the session with the schema marker + atomic write. Readers
    // use [_migrator] to upgrade v0 (unwrapped) files on the fly.
    final envelope = <String, Object?>{
      'schema': _kScanSchemaVersion,
      'session': stored.toJson(),
      if (undoStack.isNotEmpty)
        'undoStack': [
          for (final s in _truncateUndo(undoStack)) s.toJson(),
        ],
    };
    await atomicWriteString(file, jsonEncode(envelope));
    _log.i('saved', {
      'id': session.id,
      'pages': pages.length,
      'undoStack':
          undoStack.isEmpty ? 0 : _truncateUndo(undoStack).length,
    });
  }

  static List<ScanSession> _truncateUndo(List<ScanSession> stack) {
    if (stack.length <= kPersistedUndoDepth) return stack;
    return stack.sublist(stack.length - kPersistedUndoDepth);
  }

  /// VIII.16 — the truncated undo stack persisted alongside the
  /// session in [save]. Bounded at 5 entries so the on-disk file
  /// stays compact (each entry is a full session snapshot).
  /// Pre-VIII.16 sessions without the field decode to an empty
  /// stack on load.
  Future<({ScanSession session, List<ScanSession> undoStack})?>
      loadWithUndo(String sessionId) async {
    final root = await _root();
    final file = File(p.join(root.path, '$sessionId.json'));
    if (!file.existsSync()) return null;
    try {
      final j = jsonDecode(await file.readAsString())
          as Map<String, dynamic>;
      final migrated = _migrator.migrate(j);
      if (migrated == null) return null;
      final sessionJson = migrated['session'];
      if (sessionJson is! Map<String, dynamic>) return null;
      final session = ScanSession.fromJson(sessionJson);
      final undoStackJson = migrated['undoStack'];
      final undoStack = <ScanSession>[];
      if (undoStackJson is List) {
        for (final raw in undoStackJson) {
          if (raw is Map<String, dynamic>) {
            try {
              undoStack.add(ScanSession.fromJson(raw));
            } catch (e) {
              _log.w('skipped malformed undo entry', {'err': e.toString()});
            }
          }
        }
      }
      return (session: session, undoStack: undoStack);
    } catch (e) {
      _log.w('loadWithUndo failed', {'id': sessionId, 'err': e.toString()});
      return null;
    }
  }

  Future<List<ScanSession>> loadAll() async {
    final sw = Stopwatch()..start();
    final root = await _root();
    if (!root.existsSync()) return const [];
    final list = <ScanSession>[];
    for (final f in root.listSync()) {
      if (f is! File || !f.path.endsWith('.json')) continue;
      try {
        final j = jsonDecode(await f.readAsString()) as Map<String, dynamic>;
        final migrated = _migrator.migrate(j);
        if (migrated == null) {
          _log.w('migration gap, skipping session', {
            'path': f.path,
            'got': j['schema'],
            'expected': _kScanSchemaVersion,
          });
          continue;
        }
        final sessionJson = migrated['session'];
        if (sessionJson is! Map<String, dynamic>) {
          _log.w('missing session body after migration', {'path': f.path});
          continue;
        }
        list.add(ScanSession.fromJson(sessionJson));
      } catch (e) {
        _log.w('bad session file', {'path': f.path, 'err': e.toString()});
      }
    }
    list.sort((a, b) => b.createdAt.compareTo(a.createdAt));
    _log.d('loaded', {'n': list.length, 'ms': sw.elapsedMilliseconds});
    return list;
  }

  Future<void> delete(String sessionId) async {
    final root = await _root();
    final file = File(p.join(root.path, '$sessionId.json'));
    if (file.existsSync()) await file.delete();
    final dir = Directory(p.join(root.path, sessionId));
    if (dir.existsSync()) await dir.delete(recursive: true);
    _log.i('deleted', {'id': sessionId});
  }
}
