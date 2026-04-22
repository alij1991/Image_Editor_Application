import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';

/// Phase V.7: run [worker] across every item in [items] with at most
/// [concurrency] tasks in flight at once.
///
/// The common alternative — `Future.wait(items.map(worker))` — kicks
/// every call off in parallel. For work that contends on a shared
/// bottleneck (asset-bundle reads during the 23-shader preload),
/// unbounded parallel is **slower** on weak devices because the
/// scheduler thrashes between work items. A bounded pool lets the
/// first N finish cleanly before starting the next wave.
///
/// ## Semantics
///
/// - **Order**: [worker] is called on items in iteration order, but
///   calls are not synchronized past that. A later item can
///   complete before an earlier one.
/// - **Exceptions**: workers that don't throw continue draining the
///   queue — a failure in one worker does NOT halt siblings. After
///   all workers finish, the FIRST thrown exception is re-thrown
///   from this function (matches `Future.wait`'s default). Callers
///   who want per-item outcomes (without rethrow) should use
///   [runBoundedParallelSettled]; callers who want eager halt on
///   error should wrap the worker to flip a shared abort flag.
/// - **Concurrency == 1**: sequential execution. Useful for
///   force-serializing contention-heavy workloads for a baseline
///   comparison.
/// - **Empty [items]**: returns immediately.
///
/// ## Why a bespoke helper instead of the `pool` package
///
/// The `pool` package would add a dependency and ~400 lines of API
/// surface for what the codebase needs here: a single function call.
/// This file is 40 lines total including assertions + docs and has
/// no side effects outside the caller's futures. Future Phase VI
/// items that need richer semantics (priorities, per-item timeouts)
/// can graduate to `pool` at that point.
Future<void> runBoundedParallel<I>({
  required Iterable<I> items,
  required int concurrency,
  required Future<void> Function(I item) worker,
}) async {
  assert(concurrency >= 1, 'concurrency must be >= 1');
  final queue = items.toList(growable: false);
  if (queue.isEmpty) return;
  int nextIndex = 0;

  // Run one "worker thread" — a microtask loop that grabs the next
  // index atomically (single-threaded event loop: `nextIndex++` is
  // synchronous and no `await` interleaves before the index is
  // captured), runs the worker, then loops.
  Future<void> runOne() async {
    while (true) {
      final i = nextIndex++;
      if (i >= queue.length) return;
      await worker(queue[i]);
    }
  }

  final workerCount = math.min(concurrency, queue.length);
  await Future.wait([
    for (int w = 0; w < workerCount; w++) runOne(),
  ]);
}

/// Per-item outcome returned by [runBoundedParallelSettled].
@immutable
class BoundedParallelResult<I> {
  const BoundedParallelResult.success(this.item) : error = null;
  const BoundedParallelResult.failure(this.item, Object e) : error = e;
  final I item;
  final Object? error;
  bool get isSuccess => error == null;
}

/// Variant of [runBoundedParallel] that **does not rethrow** on
/// worker failure. Every item gets a result; callers inspect the
/// returned list for per-item outcomes.
///
/// Useful when the caller wants "best-effort all items" — e.g.
/// shader preload: a single missing/corrupt shader shouldn't nuke
/// the other 22 loads.
Future<List<BoundedParallelResult<I>>> runBoundedParallelSettled<I>({
  required Iterable<I> items,
  required int concurrency,
  required Future<void> Function(I item) worker,
}) async {
  assert(concurrency >= 1, 'concurrency must be >= 1');
  final queue = items.toList(growable: false);
  if (queue.isEmpty) return const [];
  final results =
      List<BoundedParallelResult<I>?>.filled(queue.length, null, growable: false);
  int nextIndex = 0;

  Future<void> runOne() async {
    while (true) {
      final i = nextIndex++;
      if (i >= queue.length) return;
      final item = queue[i];
      try {
        await worker(item);
        results[i] = BoundedParallelResult.success(item);
      } catch (e) {
        results[i] = BoundedParallelResult.failure(item, e);
      }
    }
  }

  final workerCount = math.min(concurrency, queue.length);
  await Future.wait([
    for (int w = 0; w < workerCount; w++) runOne(),
  ]);
  return results.cast<BoundedParallelResult<I>>();
}
