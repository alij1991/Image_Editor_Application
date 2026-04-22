import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../../../core/io/atomic_file.dart';
import '../../../core/logging/app_logger.dart';

final _log = AppLogger('StyleVectorCache');

/// Phase V.5: sha256-keyed disk cache for Magenta style-prediction
/// 100-float32 vectors.
///
/// ## Why
///
/// `StylePredictService.predictFromPath` decodes the reference image
/// and runs ML Kit against it to produce a 100-dimensional bottleneck
/// vector. The vector depends **only** on the image bytes — same
/// image bytes → bit-identical vector — so caching by
/// `sha256(imageBytes)` lets a repeat "apply custom style" on the
/// same reference image skip the entire ML Kit pass.
///
/// The cache persists across sessions: vectors sit in
/// `<AppDocs>/style_vectors/<sha>.bin` as raw little-endian
/// float32 (400 bytes per file). Cross-session survival is the
/// actual win — a ~1 s predict call becomes a ~2 ms file read.
///
/// ## Concurrency / failure model
///
/// - **No in-flight coalescing**: if the user taps "apply style"
///   twice rapidly on the same file, both calls hash the file,
///   both miss the cold cache, both compute, both write to the
///   same target path (second write wins, both writes are atomic).
///   Cheap and correct; a future [FaceDetectionCache]-style
///   in-flight future map can be layered on top if motivated by a
///   trace.
/// - **Write atomicity**: via [atomicWriteBytes] — a crash
///   mid-write leaves the prior vector intact (or absent on first
///   write). No half-written files can poison later reads.
/// - **Corrupt file tolerance**: [load] validates byte length
///   against [vectorLength] * 4; wrong-size files return null and
///   the caller recomputes.
/// - **Test seam**: pass `rootOverride` to route reads/writes into
///   a tempDir, skipping `path_provider`.
class StyleVectorCache {
  StyleVectorCache({
    Directory? rootOverride,
    this.vectorLength = 100,
  }) : _rootOverride = rootOverride;

  /// Optional root for tests (skips `path_provider`). Production
  /// callers leave this null.
  final Directory? _rootOverride;

  /// Dimension of the style vector. Magenta style-prediction is
  /// always 100 — constructor-configurable only for testing.
  final int vectorLength;

  int _debugComputeCallCount = 0;
  int _debugCacheHitCount = 0;

  Future<Directory> _root() async {
    final override = _rootOverride;
    if (override != null) {
      if (!override.existsSync()) override.createSync(recursive: true);
      return override;
    }
    final docs = await getApplicationDocumentsDirectory();
    final dir = Directory(p.join(docs.path, 'style_vectors'));
    if (!dir.existsSync()) dir.createSync(recursive: true);
    return dir;
  }

  /// sha256 of the bytes at [path] as 64-char lowercase hex. Used
  /// as the cache key. Throws if [path] can't be read — the
  /// caller's responsibility (the file's about to be decoded
  /// anyway; an unreadable file fails both the cache probe and the
  /// compute path equivalently).
  Future<String> hashFile(String path) async {
    final bytes = await File(path).readAsBytes();
    return sha256.convert(bytes).toString();
  }

  /// Read the cached vector for [sha], or null if no file exists
  /// or the file is corrupt (wrong byte length / read error).
  Future<Float32List?> load(String sha) async {
    try {
      final file = File(p.join((await _root()).path, '$sha.bin'));
      if (!file.existsSync()) return null;
      final bytes = await file.readAsBytes();
      final expected = vectorLength * 4;
      if (bytes.length != expected) {
        _log.w('load: size mismatch — treating as corrupt', {
          'sha': sha,
          'expectedBytes': expected,
          'actualBytes': bytes.length,
        });
        return null;
      }
      // Bytes were atomic-written from `vector.buffer.asUint8List()`,
      // so the underlying representation is already little-endian
      // float32 on every target we ship on. Copy to a new list so
      // callers can't mutate the mmap-ish view (harmless given the
      // cache doesn't cache anything in memory, but the defensive
      // copy matches `Float32List.fromList(buffer.asFloat32List())`
      // idioms elsewhere in the codebase).
      return Float32List.fromList(
        bytes.buffer.asFloat32List(bytes.offsetInBytes, vectorLength),
      );
    } catch (e) {
      _log.w('load failed', {'sha': sha, 'error': e.toString()});
      return null;
    }
  }

  /// Persist [vector] under [sha]. Atomic — a crash mid-write
  /// leaves the prior vector (or nothing) in place. A wrong-length
  /// vector is logged and skipped rather than written, so a buggy
  /// upstream can't poison the cache.
  Future<void> store(String sha, Float32List vector) async {
    if (vector.length != vectorLength) {
      _log.w('store: wrong vector length — skipping', {
        'sha': sha,
        'expected': vectorLength,
        'actual': vector.length,
      });
      return;
    }
    final file = File(p.join((await _root()).path, '$sha.bin'));
    await atomicWriteBytes(file, vector.buffer.asUint8List());
    _log.d('store', {'sha': sha, 'bytes': vector.lengthInBytes});
  }

  /// Hash [stylePath], look up the cache; on hit return the cached
  /// vector, on miss invoke [compute] and persist the result.
  ///
  /// The common failure path — [compute] throws — does NOT cache
  /// anything; the cache state stays as it was and the exception
  /// propagates.
  Future<Float32List> getOrCompute({
    required String stylePath,
    required Future<Float32List> Function() compute,
  }) async {
    final sha = await hashFile(stylePath);
    final cached = await load(sha);
    if (cached != null) {
      _debugCacheHitCount++;
      _log.i('cache hit', {'sha': sha});
      return cached;
    }
    _debugComputeCallCount++;
    _log.i('cache miss — computing', {'sha': sha});
    final computed = await compute();
    await store(sha, computed);
    return computed;
  }

  /// Delete every cached vector. Used by tests + a future "clear
  /// style vectors" maintenance UI (not surfaced in V.5).
  Future<void> clear() async {
    final root = await _root();
    if (!root.existsSync()) return;
    int removed = 0;
    for (final entity in root.listSync()) {
      if (entity is File && entity.path.endsWith('.bin')) {
        await entity.delete();
        removed++;
      }
    }
    _log.i('clear', {'removed': removed});
  }

  /// Diagnostic: how many times [getOrCompute] invoked the
  /// `compute` closure (cache misses). Paired with [debugCacheHitCount]
  /// this pins the cache's hit-rate behavior in tests.
  @visibleForTesting
  int get debugComputeCallCount => _debugComputeCallCount;

  /// Diagnostic: how many [getOrCompute] calls returned cached
  /// values without invoking `compute`.
  @visibleForTesting
  int get debugCacheHitCount => _debugCacheHitCount;
}
