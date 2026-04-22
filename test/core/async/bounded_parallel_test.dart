import 'dart:async';

import 'package:flutter_test/flutter_test.dart';

import 'package:image_editor/core/async/bounded_parallel.dart';

/// Phase V.7 tests for `runBoundedParallel` +
/// `runBoundedParallelSettled`.
///
/// The tests pin the two invariants the shader-preload path relies
/// on: **bounded concurrency** (at most N workers in flight) and
/// **per-item failure isolation** in the settled variant (one
/// missing shader doesn't nuke the other 22 loads).
void main() {
  group('runBoundedParallel', () {
    test('empty input completes immediately', () async {
      int calls = 0;
      await runBoundedParallel<int>(
        items: const [],
        concurrency: 4,
        worker: (i) async => calls++,
      );
      expect(calls, 0);
    });

    test('processes every item exactly once', () async {
      final seen = <int>{};
      await runBoundedParallel<int>(
        items: List<int>.generate(50, (i) => i),
        concurrency: 4,
        worker: (i) async {
          seen.add(i);
        },
      );
      expect(seen.length, 50);
      expect(seen, {for (int i = 0; i < 50; i++) i});
    });

    test('concurrency == 1 serialises work', () async {
      int peak = 0;
      int current = 0;
      await runBoundedParallel<int>(
        items: List<int>.generate(10, (i) => i),
        concurrency: 1,
        worker: (i) async {
          current++;
          if (current > peak) peak = current;
          // Yield so another queued worker could race in.
          await Future<void>.delayed(Duration.zero);
          current--;
        },
      );
      expect(peak, 1,
          reason: 'concurrency=1 must keep in-flight count at 1');
    });

    test('concurrency == 4 caps in-flight at 4', () async {
      int peak = 0;
      int current = 0;
      await runBoundedParallel<int>(
        items: List<int>.generate(50, (i) => i),
        concurrency: 4,
        worker: (i) async {
          current++;
          if (current > peak) peak = current;
          // Yield multiple times so the scheduler can interleave
          // — the bound still has to hold.
          await Future<void>.delayed(Duration.zero);
          await Future<void>.delayed(Duration.zero);
          current--;
        },
      );
      expect(peak, lessThanOrEqualTo(4));
      expect(peak, greaterThan(1),
          reason: 'some parallelism should show with 50 items × 4 workers');
    });

    test('concurrency > items.length caps at items.length', () async {
      // 2 items with concurrency=10 shouldn't spawn 10 workers.
      int peak = 0;
      int current = 0;
      await runBoundedParallel<int>(
        items: const [1, 2],
        concurrency: 10,
        worker: (i) async {
          current++;
          if (current > peak) peak = current;
          await Future<void>.delayed(Duration.zero);
          current--;
        },
      );
      expect(peak, lessThanOrEqualTo(2));
    });

    test('workers that throw propagate; siblings keep draining the queue',
        () async {
      // Semantics match `Future.wait`: the first thrown error is
      // rethrown from the outer future after ALL workers finish,
      // not eagerly. Workers that haven't thrown keep pulling work.
      // This mirrors `Future.wait`'s default behavior and avoids
      // orphaned in-flight work.
      final seen = <int>[];
      await expectLater(
        runBoundedParallel<int>(
          items: List<int>.generate(10, (i) => i),
          concurrency: 2,
          worker: (i) async {
            seen.add(i);
            if (i == 3) throw StateError('boom on $i');
          },
        ),
        throwsA(isA<StateError>()),
      );
      // The sibling worker keeps draining the queue after the
      // throwing worker exits — this is the documented contract.
      // (`runBoundedParallelSettled` is the variant for "collect
      // every outcome and never rethrow".)
      expect(seen, contains(3),
          reason: 'throwing worker recorded its item before throwing');
      expect(seen.length, 10,
          reason: 'sibling workers drain the queue independently of '
              'the throwing worker');
    });

    test('assert rejects concurrency=0', () {
      expect(
        () => runBoundedParallel<int>(
          items: const [1],
          concurrency: 0,
          worker: (i) async {},
        ),
        throwsA(isA<AssertionError>()),
      );
    });
  });

  group('runBoundedParallelSettled', () {
    test('empty input returns empty list', () async {
      final results = await runBoundedParallelSettled<int>(
        items: const [],
        concurrency: 4,
        worker: (i) async {},
      );
      expect(results, isEmpty);
    });

    test('all successes produce all-success results', () async {
      final results = await runBoundedParallelSettled<int>(
        items: const [1, 2, 3, 4, 5],
        concurrency: 2,
        worker: (i) async {},
      );
      expect(results, hasLength(5));
      for (final r in results) {
        expect(r.isSuccess, isTrue);
        expect(r.error, isNull);
      }
      expect(results.map((r) => r.item).toSet(), {1, 2, 3, 4, 5});
    });

    test('per-item failure does NOT nuke sibling items', () async {
      // This is the shader-preload invariant: one missing .frag
      // must not stop the other 22 from loading.
      final results = await runBoundedParallelSettled<int>(
        items: const [1, 2, 3, 4, 5],
        concurrency: 2,
        worker: (i) async {
          if (i == 3) throw StateError('corrupt shader $i');
        },
      );
      expect(results, hasLength(5));
      final successes = results.where((r) => r.isSuccess).map((r) => r.item);
      final failures = results.where((r) => !r.isSuccess).toList();
      expect(successes.toSet(), {1, 2, 4, 5});
      expect(failures, hasLength(1));
      expect(failures.single.item, 3);
      expect(failures.single.error, isA<StateError>());
    });

    test('multiple failures all surface in the result list', () async {
      final results = await runBoundedParallelSettled<int>(
        items: const [1, 2, 3, 4],
        concurrency: 2,
        worker: (i) async {
          if (i.isEven) throw StateError('fail $i');
        },
      );
      final failures = results.where((r) => !r.isSuccess).toList();
      expect(failures.map((f) => f.item).toSet(), {2, 4});
    });

    test('concurrency cap holds under settled mode', () async {
      int peak = 0;
      int current = 0;
      await runBoundedParallelSettled<int>(
        items: List<int>.generate(20, (i) => i),
        concurrency: 3,
        worker: (i) async {
          current++;
          if (current > peak) peak = current;
          await Future<void>.delayed(Duration.zero);
          current--;
        },
      );
      expect(peak, lessThanOrEqualTo(3));
    });

    test('yields to event loop between items (no microtask lock)',
        () async {
      // If the worker returns a resolved future synchronously, the
      // loop mustn't starve other microtasks — pump a Completer to
      // verify.
      final completer = Completer<void>();
      Timer(const Duration(milliseconds: 10), completer.complete);
      final poolFuture = runBoundedParallelSettled<int>(
        items: List<int>.generate(50, (i) => i),
        concurrency: 4,
        worker: (i) async {},
      );
      // If the pool starved the scheduler, this would time out.
      await Future.any([completer.future, poolFuture]);
      // Either order is fine; just verify both complete.
      await completer.future;
      await poolFuture;
    });
  });
}
