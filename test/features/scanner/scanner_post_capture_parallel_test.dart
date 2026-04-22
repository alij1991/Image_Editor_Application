import 'dart:async';

import 'package:flutter_test/flutter_test.dart';

import 'package:image_editor/features/scanner/application/scanner_notifier.dart';
import 'package:image_editor/features/scanner/domain/models/scan_models.dart';

/// Phase VI.5 — contract tests for [processPendingPagesParallel].
///
/// The helper is the extraction point from
/// `ScannerNotifier._processAllPages`. Tests here drive it directly
/// with stub futures so we can observe concurrency, ordering, and
/// commit plumbing without standing up a real [ScanImageProcessor]
/// (which would want isolate + OpenCV + temp-file machinery).
///
/// The underlying [runBoundedParallel] semantics (cap, sibling-
/// failure tolerance, empty-input short-circuit, etc.) are already
/// pinned by `test/core/async/bounded_parallel_test.dart` from Phase
/// V.7; this file focuses on the glue the notifier adds on top —
/// commit is called once per input, commit count matches input, and
/// the public concurrency constant holds the documented value.
void main() {
  ScanPage page(String id) => ScanPage(id: id, rawImagePath: '/tmp/$id.jpg');

  group('processPendingPagesParallel', () {
    test('empty input short-circuits without calling process or commit',
        () async {
      var processCalls = 0;
      var commitCalls = 0;
      await processPendingPagesParallel(
        pending: const [],
        concurrency: 4,
        process: (p) async {
          processCalls++;
          return p;
        },
        commit: (_) => commitCalls++,
      );
      expect(processCalls, 0);
      expect(commitCalls, 0);
    });

    test('every input page is processed and committed exactly once', () async {
      final pages = [for (int i = 0; i < 8; i++) page('p$i')];
      final processed = <String>[];
      final committed = <String>[];
      await processPendingPagesParallel(
        pending: pages,
        concurrency: 4,
        process: (p) async {
          processed.add(p.id);
          return p;
        },
        commit: (p) => committed.add(p.id),
      );
      // Completion order is not input order, so compare sorted sets.
      expect(processed.toSet(), {for (final p in pages) p.id});
      expect(committed.toSet(), {for (final p in pages) p.id});
      expect(processed.length, pages.length);
      expect(committed.length, pages.length);
    });

    test('concurrency cap holds: at most N processes in flight at once',
        () async {
      const concurrency = 3;
      final pages = [for (int i = 0; i < 10; i++) page('p$i')];
      var active = 0;
      var peak = 0;
      await processPendingPagesParallel(
        pending: pages,
        concurrency: concurrency,
        process: (p) async {
          active++;
          if (active > peak) peak = active;
          // Yield to the scheduler so sibling workers get a chance
          // to enter the function before this one exits — otherwise
          // the synchronous path would see peak == 1 even with a
          // concurrency of 3.
          await Future<void>.delayed(const Duration(milliseconds: 2));
          active--;
          return p;
        },
        commit: (_) {},
      );
      expect(peak, lessThanOrEqualTo(concurrency));
      // A useful sanity check: if the helper had accidentally gone
      // sequential, peak would be 1. Demand peak reached the cap
      // at least once — with 10 items and a 2 ms per-worker delay,
      // all 3 slots overlap before any finishes.
      expect(peak, concurrency);
    });

    test('single-page input runs once and does not crash '
        'when concurrency > item count', () async {
      final processed = <String>[];
      final committed = <String>[];
      await processPendingPagesParallel(
        pending: [page('only')],
        concurrency: 8,
        process: (p) async {
          processed.add(p.id);
          return p;
        },
        commit: (p) => committed.add(p.id),
      );
      expect(processed, ['only']);
      expect(committed, ['only']);
    });

    test('commit receives the value returned by process (transform '
        'survives the pipeline)', () async {
      final pages = [page('a'), page('b'), page('c')];
      final committed = <ScanPage>[];
      await processPendingPagesParallel(
        pending: pages,
        concurrency: 2,
        process: (p) async =>
            // Simulate the real processor's "sets processedImagePath"
            // behaviour so we can distinguish the pre/post objects.
            p.copyWith(processedImagePath: '/tmp/proc/${p.id}.jpg'),
        commit: committed.add,
      );
      expect(committed.length, 3);
      for (final p in committed) {
        expect(p.processedImagePath, '/tmp/proc/${p.id}.jpg');
      }
    });

    test('worker exception bubbles up after siblings drain '
        '(inherits runBoundedParallel contract)', () async {
      final pages = [page('a'), page('b'), page('c'), page('d')];
      final committed = <String>[];
      await expectLater(
        processPendingPagesParallel(
          pending: pages,
          concurrency: 2,
          process: (p) async {
            if (p.id == 'b') throw StateError('boom on b');
            return p;
          },
          commit: (p) => committed.add(p.id),
        ),
        throwsA(isA<StateError>()),
      );
      // Siblings ran to completion — the helper is best-effort.
      // 'b' never commits (it threw); a/c/d do.
      expect(committed.toSet().containsAll({'a', 'c', 'd'}), isTrue);
      expect(committed.contains('b'), isFalse);
    });

    test('commit sees values as futures resolve (not batched at the end)',
        () async {
      // Release page B before A so the commit order diverges from
      // input order. Confirms the helper fires commit per-completion,
      // not as an end-of-batch flush.
      final aGate = Completer<void>();
      final bGate = Completer<void>();
      final pages = [page('a'), page('b')];
      final committedOrder = <String>[];

      final runFuture = processPendingPagesParallel(
        pending: pages,
        concurrency: 2,
        process: (p) async {
          if (p.id == 'a') await aGate.future;
          if (p.id == 'b') await bGate.future;
          return p;
        },
        commit: (p) => committedOrder.add(p.id),
      );

      // Let workers start.
      await Future<void>.delayed(Duration.zero);
      bGate.complete();
      // B's commit should fire before A's.
      await Future<void>.delayed(Duration.zero);
      expect(committedOrder, ['b']);
      aGate.complete();
      await runFuture;
      expect(committedOrder, ['b', 'a']);
    });
  });

  group('kPostCaptureProcessConcurrency', () {
    test('holds the documented default of 4', () {
      expect(kPostCaptureProcessConcurrency, 4);
    });
  });
}
