import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../../../core/io/atomic_file.dart';
import '../../../core/io/schema_migration.dart';
import '../../../core/logging/app_logger.dart';
import '../../../engine/pipeline/edit_pipeline.dart';

final _log = AppLogger('ProjectStore');

/// On-disk schema version for the project *wrapper* (the envelope that
/// carries `sourcePath`, `savedAt`, `pipeline`, etc.). The pipeline
/// itself carries its own `version` inside that wrapper — see
/// [PipelineSerializer] for the inner-schema migrations.
///
/// Bump this when the wrapper's shape changes (e.g. adding a new
/// top-level field). Add a migration at the previous version to
/// [_migrator].
const int _kProjectSchemaVersion = 1;

/// Migration chain for the project wrapper. Keyed by `fromVersion`.
///
/// Today only the v0 → v1 step exists (a no-op carry for any pre-
/// schema fixture). Future wrapper shape changes append entries here;
/// existing v1 files skip migration entirely.
final SchemaMigrator _migrator = SchemaMigrator(
  currentVersion: _kProjectSchemaVersion,
  schemaField: 'schema',
  storeTag: 'ProjectStore',
  migrations: {
    // v0 (hypothetical pre-schema) → v1 is an identity carry. The
    // migrator stamps `schema: 1` after the chain so downstream readers
    // never see a v0-shaped map.
    0: (json) => json,
  },
);

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
  ///
  /// [customTitle] is preserved across saves: passing null keeps the
  /// previously stored title (so auto-save doesn't wipe a rename
  /// the user did 30 seconds ago); pass an empty string to clear it.
  Future<void> save({
    required String sourcePath,
    required EditPipeline pipeline,
    String? customTitle,
  }) async {
    final file = await _fileFor(sourcePath);
    if (file == null) return;
    // Preserve the existing title across auto-saves unless the
    // caller explicitly provided a new one. Empty string == clear.
    String? titleToWrite = customTitle;
    if (titleToWrite == null && await file.exists()) {
      try {
        final raw = await file.readAsString();
        final prior = jsonDecode(raw) as Map<String, dynamic>;
        final priorTitle = prior['customTitle'];
        if (priorTitle is String) titleToWrite = priorTitle;
      } catch (_) {
        // Corrupt prior file — drop the title; the rest of save
        // overwrites the file anyway.
      }
    }
    final body = <String, Object?>{
      'schema': _kProjectSchemaVersion,
      'sourcePath': sourcePath,
      'savedAt': DateTime.now().toIso8601String(),
      'pipeline': pipeline.toJson(),
      if (titleToWrite != null && titleToWrite.isNotEmpty)
        'customTitle': titleToWrite,
    };
    try {
      // Atomic write: tmp + rename → readers never see a truncated JSON
      // if the app is killed between flush and commit. See
      // `lib/core/io/atomic_file.dart` for the full rationale.
      await atomicWriteString(file, jsonEncode(body));
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
  /// isn't one (or it's genuinely unreadable).
  ///
  /// Policy change from the silent-drop era: older-schema wrappers are
  /// now **migrated** via [_migrator] instead of discarded. A wrapper
  /// whose schema is too new to migrate (chain gap) is still dropped,
  /// but every such case is logged with both the on-disk and current
  /// versions so the root cause is visible.
  Future<EditPipeline?> load(String sourcePath) async {
    final file = await _fileFor(sourcePath);
    if (file == null || !await file.exists()) return null;
    try {
      final raw = await file.readAsString();
      final decoded = jsonDecode(raw) as Map<String, dynamic>;
      final migrated = _migrator.migrate(decoded);
      if (migrated == null) {
        _log.w('migration chain incomplete, dropping', {
          'expected': _kProjectSchemaVersion,
          'got': decoded['schema'],
          'path': file.path,
        });
        return null;
      }
      final pipelineJson = migrated['pipeline'];
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

  /// List every persisted project, newest-first by `savedAt`. Returns
  /// an empty list when the docs dir is unavailable or contains no
  /// project files. Files that fail to parse are skipped silently —
  /// the recent-projects UI should never crash on a corrupted entry.
  ///
  /// Each entry skips loading the full pipeline; we only need the
  /// metadata (path, op count, savedAt) for the home-page list.
  Future<List<ProjectSummary>> list() async {
    final root = await _root();
    if (root == null) return const [];
    final out = <ProjectSummary>[];
    await for (final entity in root.list()) {
      if (entity is! File || !entity.path.endsWith('.json')) continue;
      try {
        final raw = await entity.readAsString();
        final decoded = jsonDecode(raw) as Map<String, dynamic>;
        final migrated = _migrator.migrate(decoded);
        if (migrated == null) {
          _log.w('list: migration gap, skipping entry', {
            'path': entity.path,
            'got': decoded['schema'],
            'expected': _kProjectSchemaVersion,
          });
          continue;
        }
        final src = migrated['sourcePath'] as String?;
        final savedAtStr = migrated['savedAt'] as String?;
        final pipeline = migrated['pipeline'] as Map<String, dynamic>?;
        if (src == null || savedAtStr == null || pipeline == null) continue;
        final ops = pipeline['operations'];
        final opCount = ops is List ? ops.length : 0;
        final title = migrated['customTitle'];
        out.add(ProjectSummary(
          sourcePath: src,
          savedAt: DateTime.tryParse(savedAtStr) ?? DateTime.now(),
          opCount: opCount,
          jsonFile: entity,
          customTitle: title is String && title.isNotEmpty ? title : null,
        ));
      } catch (e) {
        _log.w('list: skip unreadable',
            {'path': entity.path, 'error': e.toString()});
      }
    }
    out.sort((a, b) => b.savedAt.compareTo(a.savedAt));
    return out;
  }
}

/// Lightweight metadata for a persisted project. Used by the home
/// page's recent-projects strip — does not load the pipeline itself.
class ProjectSummary {
  ProjectSummary({
    required this.sourcePath,
    required this.savedAt,
    required this.opCount,
    required this.jsonFile,
    this.customTitle,
  });

  /// The absolute path of the source image this project edits.
  final String sourcePath;

  /// When the auto-save last persisted this project.
  final DateTime savedAt;

  /// Number of edit operations in the saved pipeline. 0 means an
  /// untouched session — useful to filter or de-emphasise in the UI.
  final int opCount;

  /// The on-disk JSON file backing this entry. Exposed so callers can
  /// delete it without re-resolving the path digest.
  final File jsonFile;

  /// User-chosen display name for the session (e.g. "Trip to Big
  /// Sur"). Null when the user hasn't renamed the project — in that
  /// case the recents strip falls back to the source-image filename.
  final String? customTitle;

  /// Display name preferred over the bare filename when present.
  String displayLabel(String fallback) {
    if (customTitle != null && customTitle!.isNotEmpty) return customTitle!;
    return fallback;
  }
}
