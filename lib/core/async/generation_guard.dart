import 'package:flutter/foundation.dart' show visibleForTesting;

/// Per-key monotonic generation counter for async-result commit guards.
///
/// The pattern:
/// 1. Caller **bumps** the counter for a key (`begin`) and keeps the
///    returned id on the local stack.
/// 2. Some async work runs — an IO, a bake, a decode, an inference.
/// 3. Before committing the result, caller checks the captured id is
///    still the **latest** issued for that key (`isLatest`). If a
///    newer `begin` has fired in the meantime (rapid user input, a
///    concurrent path, a callback racing a decode) the captured id no
///    longer matches and the result is stale.
///
/// Canonical usage:
/// ```dart
/// final stamp = guard.begin(pageId);
/// final processed = await processor.process(page);
/// if (!guard.isLatest(pageId, stamp)) return; // Stale; drop.
/// commit(processed);
/// ```
///
/// Dart's single-isolate model means the counter only needs to survive
/// `await` interleavings on the main isolate; [begin] and [isLatest]
/// are synchronous Map ops, so they cannot be torn by the scheduler.
/// **Not** thread-safe — cross-isolate callers must add their own
/// mutex.
///
/// Call sites at introduction:
/// - `ScannerNotifier._processGen` — per-page reprocess keyed by
///   `pageId` (rapid filter / corner / rotation taps).
/// - `EditorSession._curveBakeGen` — single-slot keyed by the constant
///   `'curve'` (a newer curve authored mid-bake invalidates the
///   in-flight LUT encode).
/// - `EditorSession._cutoutGen` — per-layer keyed by `layerId`
///   (PNG decode during cutout hydrate vs a fresh AI segmentation
///   landing in the same slot).
///
/// Keeping the semantics of these three cases aligned — and pinned by
/// the same unit tests — lets future async-result commit sites ride
/// the same rails without reinventing the race-guard pattern.
class GenerationGuard<K> {
  final Map<K, int> _gen = <K, int>{};

  /// Start an op for [key]. Increments the counter and returns the new
  /// id. Callers capture this and pass it to [isLatest] on completion.
  ///
  /// First call for an unseen key yields 1; each subsequent call for
  /// the same key increments by 1. Keys are independent.
  int begin(K key) {
    final next = (_gen[key] ?? 0) + 1;
    _gen[key] = next;
    return next;
  }

  /// True iff [stamp] is still the latest id issued via [begin] for
  /// [key]. Use this before committing an async result — a `false`
  /// return means a later [begin] already claimed the slot, so the
  /// result is stale and should be discarded.
  ///
  /// Returns false for unknown keys (nothing was ever stamped, so
  /// there is no "latest" to match).
  bool isLatest(K key, int stamp) => _gen[key] == stamp;

  /// Drop tracking for [key]. The next [begin] for the same key starts
  /// back at 1. Use when the entity that owned the key is deleted — e.g.
  /// a scan page removed from the session or a layer destroyed.
  ///
  /// In-flight ops keyed on the forgotten key will fail their
  /// [isLatest] check (the key is absent → no stamp matches), so their
  /// results will be discarded as stale. That is the intended behaviour
  /// when the owning entity is gone.
  void forget(K key) => _gen.remove(key);

  /// Drop all tracked generations. Use when the entire context resets
  /// (e.g. session disposed, scanner cleared). Any in-flight ops will
  /// fail their [isLatest] check and drop their results.
  void clear() => _gen.clear();

  /// Number of tracked keys. Exposed for test observability only;
  /// production code has no need to count keys.
  @visibleForTesting
  int get trackedKeyCount => _gen.length;

  /// Current generation for [key], or 0 when untracked. Test-only.
  @visibleForTesting
  int generationOf(K key) => _gen[key] ?? 0;
}
