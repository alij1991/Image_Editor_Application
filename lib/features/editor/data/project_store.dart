import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../../../core/logging/app_logger.dart';
import '../../../engine/pipeline/edit_pipeline.dart';

final _log = AppLogger('ProjectStore');

/// On-disk schema version. Bump when [EditPipeline.fromJson] changes
/// shape in a way that needs a migration. Older project files with a
/// missing or lower version are silently dropped (we'd rather lose
/// stale state than load garbage and crash mid-render).
const int _kProjectSchemaVersion = 1;

/// Writes/reads the parametric edit pipeline as JSON, keyed by a
/// digest of the source-image path. Used to:
///
///   - **Auto-save** every committed pipeline so a crash, kill, or
///     accidental "Discard & exit" doesn't lose the user's work.
///   - **Auto-restore** when the user reopens a previously-edited
///     image. The editor session calls [load] on open and applies the
///     returned pipeline before the first frame.
///
/// The store is keyed by `sha256(sourcePath)` so different photos
/// don't collide and re-opening the same path always lands on the
/// same project file. Files live under
/// `ApplicationDocumentsDirectory/projects/`.
///
/// Failures are non-fatal — [load] returns null on any error (missing
/// file, malformed JSON, schema mismatch) and [save] swallows IO
/// errors after logging. Editing must keep working even if the docs
/// dir is unavailable (e.g. corrupted sandbox, no platform channel
/// during tests).
class ProjectStore {
  ProjectStore({Directory? rootOverride}) : _rootOverride = rootOverride;

  /// Optional root for tests (skips path_provider, which isn't
  /// available in pure flutter_test runs). Production code passes
  /// nothing.
  final Directory? _rootOverride;
  Directory? _resolvedRoot;

  Future<Directory?> _root() async {
    if (_resolvedRoot != null) return _resolvedRoot;
    if (_rootOverride != null) {
      _resolvedRoot = _rootOverride;
      await _resolvedRoot!.create(recursive: true);
      return _resolvedRoot;
    }
    try {
      final docs = await getApplicationDocumentsDirectory();
      _resolvedRoot = Directory(p.join(docs.path, 'projects'));
      await _resolvedRoot!.create(recursive: true);
      return _resolvedRoot;
    } catch (e) {
      _log.w('docs dir unavailable, persistence off',
          {'error': e.toString()});
      return null;
    }
  }

  static String _keyFor(String sourcePath) =>
      sha256.convert(utf8.encode(sourcePath)).toString();

  Future<File?> _fileFor(String sourcePath) async {
    final root = await _root();
    if (root == null) return null;
    return File(p.join(root.path, '${_keyFor(sourcePath)}.json'));
  }

  /// Persist [pipeline] for [sourcePath]. Best-effort — IO failures
  /// log but don't throw, so the editor's commit path can fire-and-
  /// forget without wrapping every call in try/catch.
  Future<void> save({
    required String sourcePath,
    required EditPipeline pipeline,
  }) async {
    final file = await _fileFor(sourcePath);
    if (file == null) return;
    final body = <String, Object?>{
      'schema': _kProjectSchemaVersion,
      'sourcePath': sourcePath,
      'savedAt': DateTime.now().toIso8601String(),
      'pipeline': pipeline.toJson(),
    };
    try {
      await file.writeAsString(jsonEncode(body), flush: true);
      _log.d('saved', {
        'path': file.path,
        'ops': pipeline.operations.length,
      });
    } catch (e, st) {
      _log.w('save failed', {'error': e.toString(), 'path': file.path});
      _log.e('save trace', error: e, stackTrace: st);
    }
  }

  /// Load the persisted pipeline for [sourcePath], or null if there
  /// isn't one (or it's stale / unreadable).
  Future<EditPipeline?> load(String sourcePath) async {
    final file = await _fileFor(sourcePath);
    if (file == null || !await file.exists()) return null;
    try {
      final raw = await file.readAsString();
      final decoded = jsonDecode(raw) as Map<String, dynamic>;
      final schema = decoded['schema'];
      if (schema != _kProjectSchemaVersion) {
        _log.w('schema mismatch, dropping', {
          'expected': _kProjectSchemaVersion,
          'got': schema,
        });
        return null;
      }
      final pipelineJson = decoded['pipeline'];
      if (pipelineJson is! Map<String, dynamic>) return null;
      final pipeline = EditPipeline.fromJson(pipelineJson);
      _log.i('loaded', {
        'path': file.path,
        'ops': pipeline.operations.length,
      });
      return pipeline;
    } catch (e, st) {
      _log.w('load failed', {'error': e.toString(), 'path': file.path});
      _log.e('load trace', error: e, stackTrace: st);
      return null;
    }
  }

  /// Delete the persisted project for [sourcePath]. Used when the
  /// user explicitly resets / discards their edits.
  Future<void> delete(String sourcePath) async {
    final file = await _fileFor(sourcePath);
    if (file == null || !await file.exists()) return;
    try {
      await file.delete();
      _log.i('deleted', {'path': file.path});
    } catch (e) {
      _log.w('delete failed', {'error': e.toString(), 'path': file.path});
    }
  }
}
