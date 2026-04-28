import '../../../core/logging/app_logger.dart';
import 'face_detection_service.dart';

final _log = AppLogger('FaceDetectionCache');

/// Session-scoped cache of face-detection results, keyed by source
/// path.
///
/// **Why this exists (Phase V.1)**: applying Eye Brighten + Teeth
/// Whiten + Portrait Smooth on the same source image today pays
/// 3× ML Kit face detection (~3 × 700 ms ≈ 2.1 s of user-visible
/// wait). The four beauty services all detect the exact same faces
/// on the exact same pixels; reusing the first result is free
/// correctness-wise and wins the single biggest perf win the
/// [IMPROVEMENTS](docs/IMPROVEMENTS.md) register called out.
///
/// Owned by [EditorSession]; one instance per session. Lives for the
/// lifetime of the session and is implicitly dropped with it — the
/// cache holds lists of immutable [DetectedFace] records (no
/// native resources), so no explicit dispose step is required.
///
/// ## Cache semantics
///
/// - **Key**: the source path string. Identity-compare at the map
///   level; no normalization (the caller passes the same string
///   the detector would have received).
/// - **Value**: a `Future<List<DetectedFace>>`, not the resolved
///   list. This lets concurrent callers (e.g. the user mashing
///   Smooth + Brighten rapid-fire) converge on a single in-flight
///   detection — the second caller awaits the same future the
///   first caller kicked off.
/// - **Failure handling**: failures are NOT cached. If the injected
///   [detect] closure throws, the entry is removed from the cache
///   so the next caller retries the detection. Empty-list
///   **successes** (detector ran and found no faces) ARE cached —
///   "no faces found" is a valid, stable result.
/// - **Disposal races**: the cache does NOT track session disposal.
///   Callers are responsible for discarding results received after
///   their session was closed. Matches the pattern used by
///   [GenerationGuard] in `core/async/generation_guard.dart`.
class FaceDetectionCache {
  FaceDetectionCache();

  final Map<String, Future<List<DetectedFace>>> _inflight = {};

  /// XVI.38 — synchronously-readable mirror of the inflight map for
  /// resolved entries only. Populated when a `getOrDetect` future
  /// completes successfully so the smart-crop UI can probe "do we
  /// already know the faces" without awaiting and without firing a
  /// detection. Empty-list entries (cached "no faces") still count
  /// as resolved.
  final Map<String, List<DetectedFace>> _resolved = {};

  int _debugDetectCallCount = 0;

  /// Return the cached [DetectedFace] list for [sourcePath], or
  /// invoke [detect] and cache its future if this is the first
  /// call for that path.
  ///
  /// Concurrent callers with the same [sourcePath] see the same
  /// in-flight future; only the first caller actually fires
  /// [detect].
  ///
  /// [detect] is invoked lazily — a cache hit does NOT invoke it at
  /// all, so the closure's side effects (e.g. a call-count
  /// increment in tests) fire exactly once per cache miss.
  Future<List<DetectedFace>> getOrDetect({
    required String sourcePath,
    required Future<List<DetectedFace>> Function() detect,
  }) async {
    final existing = _inflight[sourcePath];
    if (existing != null) {
      _log.d('hit', {'path': sourcePath});
      return existing;
    }
    _log.d('miss', {'path': sourcePath});
    _debugDetectCallCount++;
    final future = detect();
    _inflight[sourcePath] = future;
    try {
      final result = await future;
      // XVI.38 — mirror the resolved value so `tryGetCached` can
      // serve subsequent reads synchronously (the smart-crop chip
      // tap shouldn't await a detection it could've reused).
      _resolved[sourcePath] = result;
      return result;
    } catch (_) {
      // A failure is an invalidation: if the caller retries, we
      // want them to actually re-run the detector, not re-hit a
      // cached error. Remove before rethrowing.
      _inflight.remove(sourcePath);
      rethrow;
    }
  }

  /// XVI.38 — synchronous read of an already-resolved entry. Returns
  /// null when nothing is cached for [sourcePath] (either no detection
  /// has been kicked off, OR a detection is in flight but hasn't
  /// resolved yet). Empty-list "no faces" results return an empty
  /// list, not null — callers can distinguish "haven't tried" from
  /// "tried, found nothing".
  List<DetectedFace>? tryGetCached(String sourcePath) {
    return _resolved[sourcePath];
  }

  /// Drop every cached entry. Intended for session-level state
  /// resets (e.g. the user switches source images in place).
  void clear() {
    if (_inflight.isEmpty && _resolved.isEmpty) return;
    _log.d('clear', {'entries': _inflight.length});
    _inflight.clear();
    _resolved.clear();
  }

  /// Diagnostic counter of how many times the [detect] closure has
  /// actually been invoked. Read by the owning [EditorSession] so
  /// end-to-end tests can assert the Phase V.1 invariant — three
  /// sequential `getOrDetect` calls on the same path → 1 detection.
  ///
  /// Left un-annotated (vs `@visibleForTesting`) because the session
  /// forwards it through its own `@visibleForTesting` getter; the
  /// annotation on the session-layer alone is the compiler-enforced
  /// "tests only" boundary we care about.
  int get debugDetectCallCount => _debugDetectCallCount;

  /// Number of source paths currently tracked. Read by session-level
  /// diagnostics and test assertions.
  int get trackedPathCount => _inflight.length;
}
