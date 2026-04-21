import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../../../core/io/atomic_file.dart';
import '../../../core/io/compressed_json.dart';
import '../../../core/io/schema_migration.dart';
import '../../../core/logging/app_logger.dart';
import '../../../engine/pipeline/edit_pipeline.dart';
import '../../../engine/pipeline/pipeline_serializer.dart';

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
/// ### Wire format
///
/// Save writes a marker-prefixed byte buffer produced by
/// [encodeCompressedJson]: `0x00` = plain JSON envelope, `0x01` =
/// gzip-compressed JSON envelope. Gzip kicks in automatically for
/// envelopes ≥ [kCompressedJsonGzipThreshold] (64 KB), which is where
/// a pipeline with heavy mask data or many ops starts to benefit.
///
/// Load tolerates legacy un-marked plain JSON on disk: files written
/// before Phase IV.2 used `writeAsString(jsonEncode(envelope))` with no
/// framing byte, and [decodeCompressedJson]'s first-byte branch treats
/// anything other than `0x00` / `0x01` as a raw UTF-8 JSON string. No
/// explicit migration is needed to carry those files forward.
///
/// ### Migration seams
///
/// Two orthogonal schema versions coexist in the file:
/// - **Wrapper** (`schema` field): migrated by [_migrator] here.
/// - **Pipeline** (`version` field nested under `pipeline`): migrated
///   by [PipelineSerializer] via [PipelineSerializer.decodeFromMap].
///
/// A rename of the envelope's `customTitle` only touches the wrapper
/// migrator; a reshape of [EditPipeline] only touches the pipeline
/// migrator. Either can evolve without disturbing the other.
///
/// ### Failure policy
///
/// Failures are non-fatal — [load] returns null on any error (missing
/// file, malformed bytes, schema mismatch) and [save] swallows IO
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

  /// One serializer per store, reused across every save/load. The
  /// serializer is stateless apart from its logger so this is safe
  /// to share; construction cost is amortised across the session.
  final PipelineSerializer _serializer = PipelineSerializer();

  /// In-memory `customTitle` cache, keyed by `sourcePath`. Value `null`
  /// means "no custom title", not "unknown" — use
  /// [Map.containsKey] to distinguish a cold cache from a known-empty
  /// entry.
  ///
  /// Populated by [load], [list], [save], and [setTitle]; invalidated
  /// by [delete]. On a warm hit, [save] skips the full envelope
  /// decode it used to do just to pull the prior title — a 600 ms-
  /// debounced auto-save in a gzipped project goes from "decode +
  /// `jsonDecode`" to a single `Map` lookup.
  ///
  /// Scoped to this [ProjectStore] instance. Two stores writing the
  /// same path (e.g. editor + home page alive simultaneously) can
  /// disagree — acceptable today because the editor route is
  /// full-screen and pops home off the stack. If a future redesign
  /// keeps them co-resident, upgrade to either a module-level cache
  /// or a file-mtime invalidation check.
  final Map<String, String?> _titleCache = {};

  /// Diagnostic counter for the cache-miss fallback path — incremented
  /// every time [save] can't resolve the prior title from the cache
  /// and has to fall back to re-reading the envelope. Tests pin
  /// cache-hit behaviour via "assert this stays 0 after warm-cache
  /// saves."
  @visibleForTesting
  int debugTitleCacheMissCount = 0;

  /// In-memory shadow of the `<root>/_index.json` sidecar — the list
  /// backing [list] since Phase IV.8. Populated on first touch (via
  /// [_ensureIndex]) and kept in sync by [save] / [setTitle] /
  /// [delete]. `null` means "cold; load or rebuild on next access."
  ///
  /// Storing the whole list on the instance is cheap (50 entries
  /// × ~150 B = ~7.5 KB) and saves the sidecar file read on every
  /// mutation that would otherwise have to do a read-modify-write
  /// cycle.
  List<ProjectSummary>? _indexShadow;

  /// Diagnostic counter for the cold-path rebuild — incremented every
  /// time [_ensureIndex] falls back to walking the projects directory
  /// (either because the sidecar is missing or because it failed to
  /// parse). Tests pin "warm reads don't walk the directory" via
  /// `expect(store.debugIndexRebuildCount, 1)` once per cold start.
  @visibleForTesting
  int debugIndexRebuildCount = 0;

  /// Sidecar filename — single file colocated with the per-project
  /// JSONs so the home page can read ONE file instead of walking 50.
  static const String _kIndexFileName = '_index.json';

  /// Schema version for the sidecar body. Written on every persist
  /// and read on every load; a future bump appends a migrator step
  /// here. The [_kProjectSchemaVersion] wrapper is distinct — the
  /// sidecar is a derived cache, not authoritative state.
  static const int _kIndexSchemaVersion = 1;

  Future<File?> _indexFile() async {
    final root = await _root();
    if (root == null) return null;
    return File(p.join(root.path, _kIndexFileName));
  }

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

  /// Load the recents index into memory. Tries the sidecar first;
  /// falls back to a directory walk on a cold instance / missing /
  /// corrupt sidecar, rebuilding + persisting the sidecar as a side
  /// effect so the next session's home open is free.
  Future<List<ProjectSummary>> _ensureIndex() async {
    if (_indexShadow != null) return _indexShadow!;
    final sidecar = await _indexFile();
    if (sidecar != null && await sidecar.exists()) {
      try {
        final raw = await sidecar.readAsString();
        final decoded = jsonDecode(raw) as Map<String, dynamic>;
        if (decoded['schema'] is int) {
          final entriesRaw = decoded['entries'];
          if (entriesRaw is List) {
            final root = await _root();
            if (root != null) {
              final entries = <ProjectSummary>[];
              for (final e in entriesRaw) {
                if (e is! Map<String, dynamic>) continue;
                final parsed = _summaryFromIndexEntry(e, root);
                if (parsed != null) entries.add(parsed);
              }
              // Warm the title cache from the same read.
              for (final s in entries) {
                _titleCache[s.sourcePath] = s.customTitle;
              }
              _indexShadow = entries;
              return _indexShadow!;
            }
          }
        }
        _log.w('sidecar present but malformed; rebuilding', {
          'path': sidecar.path,
        });
      } catch (e) {
        _log.w('sidecar unreadable; rebuilding',
            {'error': e.toString(), 'path': sidecar.path});
      }
    }
    // Fall through: rebuild from directory walk.
    _indexShadow = await _rebuildIndexFromDisk();
    await _persistIndex(_indexShadow!);
    return _indexShadow!;
  }

  /// Walk the projects directory and decode every per-project envelope
  /// to build a fresh index list. Used on cold start when the sidecar
  /// is missing or corrupt. Also warms [_titleCache] along the way.
  Future<List<ProjectSummary>> _rebuildIndexFromDisk() async {
    debugIndexRebuildCount++;
    final root = await _root();
    if (root == null) return const [];
    final out = <ProjectSummary>[];
    await for (final entity in root.list()) {
      if (entity is! File || !entity.path.endsWith('.json')) continue;
      if (p.basename(entity.path) == _kIndexFileName) continue;
      try {
        final raw = decodeCompressedJson(await entity.readAsBytes());
        final decoded = jsonDecode(raw) as Map<String, dynamic>;
        final migrated = _migrator.migrate(decoded);
        if (migrated == null) {
          _log.w('rebuild: migration gap, skipping entry', {
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
        final resolvedTitle =
            title is String && title.isNotEmpty ? title : null;
        _titleCache[src] = resolvedTitle;
        out.add(ProjectSummary(
          sourcePath: src,
          savedAt: DateTime.tryParse(savedAtStr) ?? DateTime.now(),
          opCount: opCount,
          jsonFile: entity,
          customTitle: resolvedTitle,
        ));
      } catch (e) {
        _log.w('rebuild: skip unreadable',
            {'path': entity.path, 'error': e.toString()});
      }
    }
    out.sort((a, b) => b.savedAt.compareTo(a.savedAt));
    return out;
  }

  /// Rehydrate a [ProjectSummary] from a sidecar entry. Returns null if
  /// the required fields are missing. `jsonFile` is synthesised from
  /// `sha256(sourcePath) + '.json'` under [root] — matches what
  /// [_fileFor] builds for the same path.
  ProjectSummary? _summaryFromIndexEntry(
    Map<String, dynamic> entry,
    Directory root,
  ) {
    final src = entry['sourcePath'];
    final savedAtStr = entry['savedAt'];
    if (src is! String || savedAtStr is! String) return null;
    final savedAt = DateTime.tryParse(savedAtStr);
    if (savedAt == null) return null;
    final title = entry['customTitle'];
    return ProjectSummary(
      sourcePath: src,
      savedAt: savedAt,
      opCount: entry['opCount'] is int ? entry['opCount'] as int : 0,
      jsonFile: File(p.join(root.path, '${_keyFor(src)}.json')),
      customTitle: title is String && title.isNotEmpty ? title : null,
    );
  }

  /// Write [entries] to the sidecar. Best-effort — a failure nulls
  /// the shadow so the next [_ensureIndex] rebuilds from disk, and
  /// logs but doesn't throw.
  Future<void> _persistIndex(List<ProjectSummary> entries) async {
    final sidecar = await _indexFile();
    if (sidecar == null) return;
    final body = <String, Object?>{
      'schema': _kIndexSchemaVersion,
      'entries': [
        for (final e in entries)
          <String, Object?>{
            'sourcePath': e.sourcePath,
            'savedAt': e.savedAt.toIso8601String(),
            'opCount': e.opCount,
            if (e.customTitle != null && e.customTitle!.isNotEmpty)
              'customTitle': e.customTitle,
          }
      ],
    };
    try {
      await atomicWriteString(sidecar, jsonEncode(body));
    } catch (e) {
      _log.w('sidecar write failed; marking shadow stale',
          {'error': e.toString()});
      // Force rebuild next _ensureIndex so a lost write doesn't leave
      // a divergence lingering in memory.
      _indexShadow = null;
    }
  }

  /// Update (or append) [summary] in the shadow + sidecar. Preserves
  /// the newest-first sort contract.
  Future<void> _upsertIndex(ProjectSummary summary) async {
    final index = await _ensureIndex();
    final existing =
        index.indexWhere((e) => e.sourcePath == summary.sourcePath);
    if (existing >= 0) {
      index[existing] = summary;
    } else {
      index.add(summary);
    }
    index.sort((a, b) => b.savedAt.compareTo(a.savedAt));
    await _persistIndex(index);
  }

  /// Remove [sourcePath]'s entry from the shadow + sidecar.
  Future<void> _removeFromIndex(String sourcePath) async {
    final index = await _ensureIndex();
    index.removeWhere((e) => e.sourcePath == sourcePath);
    await _persistIndex(index);
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
    // Preserve the existing title across auto-saves unless the caller
    // explicitly provided a new one. Empty string == clear.
    //
    // The cache (populated by prior [load] / [list] / [save] /
    // [setTitle] calls in this store) answers most auto-saves
    // without any disk IO. Only cold-cache paths fall through to the
    // envelope read — and the fallback then warms the cache so the
    // next auto-save is free.
    String? titleToWrite = customTitle;
    if (titleToWrite == null) {
      if (_titleCache.containsKey(sourcePath)) {
        titleToWrite = _titleCache[sourcePath];
      } else if (await file.exists()) {
        debugTitleCacheMissCount++;
        try {
          final raw = decodeCompressedJson(await file.readAsBytes());
          final prior = jsonDecode(raw) as Map<String, dynamic>;
          final priorTitle = prior['customTitle'];
          if (priorTitle is String) titleToWrite = priorTitle;
        } catch (_) {
          // Corrupt prior file — drop the title; the rest of save
          // overwrites the file anyway.
        }
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
      // Atomic write: tmp + rename → readers never see a truncated
      // buffer if the app is killed between flush and commit. The
      // marker+gzip framing is produced by [encodeCompressedJson] —
      // small envelopes stay as plain JSON (0x00 marker); envelopes
      // ≥ 64 KB gzip automatically (0x01 marker).
      final bytes = encodeCompressedJson(jsonEncode(body));
      await atomicWriteBytes(file, bytes);
      // Warm the cache with whatever we just wrote. Treat the empty
      // string the same way the on-disk envelope does (absent key →
      // null title).
      final resolved = (titleToWrite == null || titleToWrite.isEmpty)
          ? null
          : titleToWrite;
      _titleCache[sourcePath] = resolved;
      // Mirror the write into the sidecar index so the home page's
      // next [list] call doesn't have to walk the directory.
      await _upsertIndex(ProjectSummary(
        sourcePath: sourcePath,
        savedAt: DateTime.parse(body['savedAt']! as String),
        opCount: pipeline.operations.length,
        jsonFile: file,
        customTitle: resolved,
      ));
      _log.d('saved', {
        'path': file.path,
        'ops': pipeline.operations.length,
        'bytes': bytes.length,
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
      // `readAsBytes` + `decodeCompressedJson` handles all three
      // on-disk formats: modern marker-byte plain, modern marker-byte
      // gzip, and pre-Phase-IV.2 legacy plain JSON (no marker).
      final raw = decodeCompressedJson(await file.readAsBytes());
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
      // Hand off to [PipelineSerializer.decodeFromMap] so the inner
      // pipeline-schema migrator runs too. This replaces the
      // Phase-III inline `EditPipeline.fromJson(pipelineJson)` call
      // and keeps both migration seams active on every load.
      final pipeline = _serializer.decodeFromMap(pipelineJson);
      // Warm the title cache — every subsequent [save] on this path
      // will skip the prior-file read.
      final title = migrated['customTitle'];
      _titleCache[sourcePath] =
          title is String && title.isNotEmpty ? title : null;
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
      // Invalidate the cache entry so a subsequent [save] for the
      // same path doesn't preserve a ghost title.
      _titleCache.remove(sourcePath);
      // Drop the sidecar entry too — home page's next [list] call
      // must not show a phantom tile for a deleted project.
      await _removeFromIndex(sourcePath);
      _log.i('deleted', {'path': file.path});
    } catch (e) {
      _log.w('delete failed', {'error': e.toString(), 'path': file.path});
    }
  }

  /// Rename fast-path: rewrite ONLY the `customTitle` field in the
  /// on-disk envelope. The `pipeline` sub-map flows through
  /// untouched — no `fromJson` / `toJson` round-trip, no decode of
  /// operation payloads, no risk of an asymmetric encoder dropping
  /// a forward-compat field.
  ///
  /// Returns `true` when the file existed and was updated; `false`
  /// when the path has no persisted project (nothing to rename) or
  /// the file cannot be parsed / migrated.
  ///
  /// [title] is the new display name. Empty string clears the title
  /// (matches [save]'s semantics). The `savedAt` stamp is bumped so
  /// the rename counts as activity for the recent-projects sort.
  ///
  /// Robustness dividend: this path survives even when the pipeline
  /// sub-map is too new for the current app to parse via
  /// `EditPipeline.fromJson` — the envelope-level operations don't
  /// care about pipeline shape. Before Phase IV.6 the home page's
  /// rename flow went through [load] + [save], so a pipeline with
  /// forward-incompatible fields would bail out the rename with a
  /// "session not found" toast even though the file was perfectly
  /// fine at the envelope level. The fast-path turns that into a
  /// successful rename.
  Future<bool> setTitle(String sourcePath, String title) async {
    final file = await _fileFor(sourcePath);
    if (file == null || !await file.exists()) {
      _log.w('setTitle: no file', {'path': sourcePath});
      return false;
    }
    try {
      final raw = decodeCompressedJson(await file.readAsBytes());
      final decoded = jsonDecode(raw) as Map<String, dynamic>;
      final migrated = _migrator.migrate(decoded);
      if (migrated == null) {
        _log.w('setTitle: migration gap, skipping', {
          'path': file.path,
          'got': decoded['schema'],
          'expected': _kProjectSchemaVersion,
        });
        return false;
      }
      if (title.isEmpty) {
        migrated.remove('customTitle');
      } else {
        migrated['customTitle'] = title;
      }
      // Warm the title cache with the new value — subsequent
      // auto-saves on this path will skip the prior-file read.
      _titleCache[sourcePath] = title.isEmpty ? null : title;
      // Bump `savedAt` so the rename bubbles to the top of the
      // recent-projects strip — matches the observable behaviour of
      // the pre-IV.6 `load + save` path (auto-save stamps a fresh
      // timestamp on every write).
      final newSavedAt = DateTime.now().toIso8601String();
      migrated['savedAt'] = newSavedAt;
      final bytes = encodeCompressedJson(jsonEncode(migrated));
      await atomicWriteBytes(file, bytes);
      // Mirror the rename into the sidecar index so [list] picks it
      // up without having to re-read the envelope.
      final pipelineJson = migrated['pipeline'] as Map<String, dynamic>?;
      final ops = pipelineJson?['operations'];
      final opCount = ops is List ? ops.length : 0;
      await _upsertIndex(ProjectSummary(
        sourcePath: sourcePath,
        savedAt: DateTime.parse(newSavedAt),
        opCount: opCount,
        jsonFile: file,
        customTitle: title.isEmpty ? null : title,
      ));
      _log.i('renamed', {
        'path': file.path,
        'title': title.isEmpty ? '(cleared)' : title,
      });
      return true;
    } catch (e, st) {
      _log.w('setTitle failed', {'error': e.toString(), 'path': file.path});
      _log.e('setTitle trace', error: e, stackTrace: st);
      return false;
    }
  }

  /// List every persisted project, newest-first by `savedAt`. Returns
  /// an empty list when the docs dir is unavailable or contains no
  /// project files.
  ///
  /// Since Phase IV.8 the list is served from a single sidecar file
  /// (`<root>/_index.json`) that [save] / [setTitle] / [delete] keep
  /// in sync. The home page's `_refreshRecents` used to do 50 full
  /// envelope decodes for 50 projects; now it does one small JSON
  /// read + parse. On a cold instance the sidecar is rebuilt from a
  /// directory walk and persisted for next time.
  Future<List<ProjectSummary>> list() async {
    final index = await _ensureIndex();
    // Return a defensive copy so callers can sort / filter without
    // corrupting the shadow.
    return List<ProjectSummary>.from(index);
  }

  /// Force a rebuild of the sidecar from the directory walk. Useful
  /// after a divergence (e.g. files arrived from a backup restore,
  /// another process mutated files behind this store). Production
  /// code doesn't need to call this today — the store auto-rebuilds
  /// on cold start or sidecar parse failure.
  @visibleForTesting
  Future<void> rebuildIndex() async {
    _indexShadow = await _rebuildIndexFromDisk();
    await _persistIndex(_indexShadow!);
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
