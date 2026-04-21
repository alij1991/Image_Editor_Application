import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../../core/logging/app_logger.dart';

final _log = AppLogger('CutoutStore');

/// Disk-backed cache of AI-layer cutout bitmaps (PNG-encoded) keyed by
/// `(sourcePath, layerId)`.
///
/// # Why it exists
///
/// AI adjustment layers (background removal, portrait smooth, face
/// reshape, sky replace, inpaint, etc.) carry their result as a
/// [ui.Image] on the layer object. Before Phase I.9 that image was
/// volatile — held only in a session-lifetime `Map<layerId, ui.Image>`
/// and wiped the moment `EditorSession.dispose` ran. On reload the
/// layer metadata came back but the pixels didn't, so the user saw
/// "nothing happened" where they'd applied a background removal an
/// hour earlier.
///
/// This store persists the raster so the next session can hydrate the
/// cutout and render the layer correctly.
///
/// # Lifecycle
///
/// - **Put**: fire-and-forget from `EditorSession._cacheCutoutImage`.
///   Failures log but don't abort the edit — losing a cutout on disk
///   is recoverable (re-run the AI op); losing an edit isn't.
/// - **Get**: called by `EditorSession.hydrateCutouts()` once per
///   session start, for every AdjustmentLayer the restored pipeline
///   carries.
/// - **Delete**: NOT called on session close — that's the point. Only
///   [deleteProject] wipes, when the user explicitly removes a whole
///   project.
/// - **Evict**: lazy; every [put] re-checks the total footprint and
///   removes oldest-mtime entries until under [diskBudgetBytes].
///
/// # Disk layout
///
/// ```
/// <AppDocs>/cutouts/<bucket>/<layerId>.png
/// ```
///
/// `<bucket>` is the first 16 hex chars of `sha256(sourcePath)`. This
/// keeps per-project cutouts grouped so `deleteProject` is an O(1)
/// recursive directory remove, avoids clashes between two projects
/// that happened to reuse the same layer UUID (effectively never, but
/// cheap insurance), and keeps the filesystem flat enough not to hit
/// per-directory file-count limits.
///
/// # Budget
///
/// 200 MB default, matching `MementoStore.diskBudgetBytes`. A
/// bg-removed 12 MP photo weighs ~40 MB as PNG, so ~5 cutouts fit
/// comfortably; heavier sessions pay the oldest-first eviction cost.
class CutoutStore {
  CutoutStore({
    Directory? rootOverride,
    this.diskBudgetBytes = 200 * 1024 * 1024,
  }) : _rootOverride = rootOverride;

  /// Optional root for tests (skips `path_provider`). Production
  /// callers leave this null.
  final Directory? _rootOverride;

  /// Soft cap on total on-disk cutout bytes. When exceeded, the
  /// oldest-mtime entries are removed until back under budget.
  final int diskBudgetBytes;

  Future<Directory> _root() async {
    final override = _rootOverride;
    if (override != null) {
      if (!override.existsSync()) override.createSync(recursive: true);
      return override;
    }
    final docs = await getApplicationDocumentsDirectory();
    final dir = Directory(p.join(docs.path, 'cutouts'));
    if (!dir.existsSync()) dir.createSync(recursive: true);
    return dir;
  }

  /// Map a [sourcePath] to its on-disk bucket directory name. First
  /// 16 chars of sha256 — collision-free at the scale any user is
  /// realistically going to reach.
  @visibleForTesting
  String bucketFor(String sourcePath) =>
      sha256.convert(utf8.encode(sourcePath)).toString().substring(0, 16);

  Future<File> _fileFor(String sourcePath, String layerId) async {
    final root = await _root();
    final bucket = Directory(p.join(root.path, bucketFor(sourcePath)));
    if (!bucket.existsSync()) bucket.createSync(recursive: true);
    return File(p.join(bucket.path, '$layerId.png'));
  }

  /// Persist [pngBytes] for `(sourcePath, layerId)`. Safe to call
  /// from fire-and-forget contexts — IO failures log but don't throw.
  /// Automatically enforces the disk budget on the way out, so long
  /// sessions can't unbounded-grow past [diskBudgetBytes].
  Future<void> put({
    required String sourcePath,
    required String layerId,
    required Uint8List pngBytes,
  }) async {
    try {
      final f = await _fileFor(sourcePath, layerId);
      await f.writeAsBytes(pngBytes, flush: true);
      _log.d('put', {
        'bucket': bucketFor(sourcePath),
        'layer': layerId,
        'bytes': pngBytes.length,
      });
      await evictUntilUnder(diskBudgetBytes);
    } catch (e, st) {
      _log.w('put failed', {
        'error': e.toString(),
        'layer': layerId,
      });
      _log.e('put trace', error: e, stackTrace: st);
    }
  }

  /// Read the PNG bytes for `(sourcePath, layerId)`, or null if
  /// nothing's cached or the file vanished between sessions.
  Future<Uint8List?> get({
    required String sourcePath,
    required String layerId,
  }) async {
    try {
      final f = await _fileFor(sourcePath, layerId);
      if (!await f.exists()) return null;
      return await f.readAsBytes();
    } catch (e) {
      _log.w('get failed', {'error': e.toString(), 'layer': layerId});
      return null;
    }
  }

  /// Remove one cutout file. Currently unused automatically — history
  /// tolerates the cutout outliving its layer so undo-past-delete
  /// works. Exposed for explicit user actions ("forget this AI
  /// result") and to keep the surface complete.
  Future<void> delete({
    required String sourcePath,
    required String layerId,
  }) async {
    try {
      final f = await _fileFor(sourcePath, layerId);
      if (await f.exists()) await f.delete();
    } catch (e) {
      _log.w('delete failed', {'error': e.toString(), 'layer': layerId});
    }
  }

  /// Drop every cutout for a given source image. Call this when the
  /// user deletes a project — orphans would otherwise linger until
  /// the disk budget evicts them.
  Future<void> deleteProject(String sourcePath) async {
    try {
      final root = await _root();
      final bucket = Directory(p.join(root.path, bucketFor(sourcePath)));
      if (bucket.existsSync()) {
        await bucket.delete(recursive: true);
        _log.i('deleteProject', {'bucket': bucketFor(sourcePath)});
      }
    } catch (e) {
      _log.w('deleteProject failed', {'error': e.toString()});
    }
  }

  /// Walk every cutout and, if the total footprint exceeds [budget],
  /// evict oldest-mtime first until under. Returns the number of
  /// evicted files.
  ///
  /// Called automatically from [put]; exposed publicly so callers
  /// under memory pressure (e.g. `didHaveMemoryPressure` → trim
  /// cutouts) can request an early trim.
  Future<int> evictUntilUnder(int budget) async {
    try {
      final root = await _root();
      if (!root.existsSync()) return 0;
      final entries = <_CutoutEntry>[];
      int total = 0;
      for (final entity in root.listSync(recursive: true)) {
        if (entity is! File) continue;
        try {
          final stat = entity.statSync();
          total += stat.size;
          entries.add(_CutoutEntry(entity, stat.size, stat.modified));
        } catch (_) {
          // Ignore per-file stat failures — partial counts are fine
          // and the next evict pass will catch up.
        }
      }
      if (total <= budget) return 0;
      entries.sort((a, b) => a.modified.compareTo(b.modified));
      int evicted = 0;
      for (final e in entries) {
        if (total <= budget) break;
        try {
          await e.file.delete();
          total -= e.size;
          evicted++;
        } catch (_) {
          // Swallow — an unreadable file doesn't help us and the
          // budget drifts closer on the next put anyway.
        }
      }
      if (evicted > 0) {
        _log.i('evicted', {
          'count': evicted,
          'remainingBytes': total,
          'budget': budget,
        });
      }
      return evicted;
    } catch (e) {
      _log.w('evictUntilUnder failed', {'error': e.toString()});
      return 0;
    }
  }

  /// Total on-disk size of all cutouts. Exposed for test assertions
  /// and for a future "Storage" settings screen.
  Future<int> totalBytes() async {
    try {
      final root = await _root();
      if (!root.existsSync()) return 0;
      int total = 0;
      for (final entity in root.listSync(recursive: true)) {
        if (entity is File) {
          try {
            total += entity.statSync().size;
          } catch (_) {}
        }
      }
      return total;
    } catch (_) {
      return 0;
    }
  }
}

class _CutoutEntry {
  _CutoutEntry(this.file, this.size, this.modified);
  final File file;
  final int size;
  final DateTime modified;
}
