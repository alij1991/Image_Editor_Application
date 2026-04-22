import 'dart:async';

import 'package:flutter_test/flutter_test.dart';

import 'package:image_editor/features/scanner/domain/models/scan_models.dart';
import 'package:image_editor/features/scanner/infrastructure/classical_corner_seed.dart';

/// Phase V.9 tests for the `CornerSeeder.seedBatch` surface, updated
/// for **Phase VI.7** — the default forwarder changed from a
/// sequential `for+await` loop to `Future.wait(...)` so per-page
/// `seed` calls fire in parallel. These tests pin the contract the
/// new default carries forward:
///
///   1. Ordering preserved (`result[i]` ↔ `input[i]`).
///   2. Exactly one `seed` call per path.
///   3. Empty input → empty output without seed invocations.
///   4. Exceptions still propagate (Future.wait default) — callers
///      wanting "best-effort" batching wrap their own try/catch
///      (`OpenCvCornerSeed.seedBatch` does this).
///
/// New VI.7 tests cover the parallelism itself: all seeds start
/// before the first completes (observable via a gated-Completer
/// setup), and a slow leading seed does not block a later one from
/// finishing first (confirms parallel dispatch semantics, which
/// sequential-forward would violate).
void main() {
  group('CornerSeeder.seedBatch — default parallel behavior', () {
    test('empty input → empty output, zero seed calls', () async {
      int seedCalls = 0;
      final seeder = _FakeSeeder((path) async {
        seedCalls++;
        return SeedResult(corners: Corners.inset(), fellBack: false);
      });
      final results = await seeder.seedBatch(const []);
      expect(results, isEmpty);
      expect(seedCalls, 0);
    });

    test('calls seed exactly once per path, preserving order', () async {
      final seenOrder = <String>[];
      final seeder = _FakeSeeder((path) async {
        seenOrder.add(path);
        // Use the 'tl' corner to carry the path index back out so
        // test assertions can verify ordering.
        final idx = path.codeUnits.last - 48; // last char as int
        return SeedResult(
          corners: Corners(
            Point2(idx / 10.0, 0),
            const Point2(1, 0),
            const Point2(1, 1),
            const Point2(0, 1),
          ),
          fellBack: false,
        );
      });
      final results = await seeder.seedBatch(const ['/a/0', '/b/1', '/c/2']);
      // seed is called in iteration order; Future.wait preserves
      // result order.
      expect(seenOrder, ['/a/0', '/b/1', '/c/2']);
      expect(results, hasLength(3));
      expect(results[0].corners.tl.x, closeTo(0.0, 1e-6));
      expect(results[1].corners.tl.x, closeTo(0.1, 1e-6));
      expect(results[2].corners.tl.x, closeTo(0.2, 1e-6));
    });

    test('preserves fellBack per-result', () async {
      int call = 0;
      final seeder = _FakeSeeder((_) async {
        final fell = call.isEven;
        call++;
        return SeedResult(corners: Corners.inset(), fellBack: fell);
      });
      final results = await seeder.seedBatch(const ['/0', '/1', '/2', '/3']);
      expect(
        results.map((r) => r.fellBack).toList(),
        [true, false, true, false],
      );
    });

    test('propagates the underlying seed exception', () async {
      final seeder = _FakeSeeder((path) async {
        if (path == '/boom') throw StateError('bad path');
        return SeedResult(corners: Corners.inset(), fellBack: false);
      });
      await expectLater(
        seeder.seedBatch(const ['/ok', '/boom']),
        throwsA(isA<StateError>()),
      );
    });

    test('single-path batch returns one result', () async {
      int calls = 0;
      final seeder = _FakeSeeder((_) async {
        calls++;
        return SeedResult(corners: Corners.inset(), fellBack: false);
      });
      final results = await seeder.seedBatch(const ['/solo']);
      expect(results, hasLength(1));
      expect(calls, 1);
    });
  });

  group('CornerSeeder.seedBatch — VI.7 parallel dispatch', () {
    test('all seeds start before any completes (parallel, not sequential)',
        () async {
      // Each seed waits on a shared "release" gate. Under sequential
      // semantics, only one seed would be in flight at a time and the
      // inflight counter would cap at 1. Under parallel, the counter
      // reaches the input length before the gate is released.
      final release = Completer<void>();
      int peak = 0;
      int active = 0;
      final seeder = _FakeSeeder((_) async {
        active++;
        if (active > peak) peak = active;
        await release.future;
        active--;
        return SeedResult(corners: Corners.inset(), fellBack: false);
      });
      // Kick off the batch; don't await yet.
      final future = seeder.seedBatch(const ['/a', '/b', '/c', '/d']);
      // Let microtasks drain so every seed call enters the worker
      // body and increments the counter.
      await Future<void>.delayed(Duration.zero);
      expect(peak, 4,
          reason: 'Future.wait default should fan out all seeds at once; '
              'peak=1 would mean the dispatch is still sequential.');
      release.complete();
      await future;
    });

    test('slow leading seed does not block a later one from finishing '
        'first (confirms true parallelism)', () async {
      final slowFirst = Completer<void>();
      final order = <String>[];
      final seeder = _FakeSeeder((path) async {
        if (path == '/slow') {
          await slowFirst.future;
        }
        order.add(path);
        return SeedResult(corners: Corners.inset(), fellBack: false);
      });
      final future = seeder.seedBatch(const ['/slow', '/fast']);
      await Future<void>.delayed(Duration.zero);
      // '/fast' resolves first because '/slow' is gated.
      expect(order, ['/fast']);
      slowFirst.complete();
      await future;
      expect(order, ['/fast', '/slow']);
    });

    test('result order is input order even when completion order differs',
        () async {
      final gateSlow = Completer<void>();
      final seeder = _FakeSeeder((path) async {
        if (path == '/slow') await gateSlow.future;
        return SeedResult(
          corners: Corners(
            Point2(path == '/slow' ? 0.9 : 0.1, 0),
            const Point2(1, 0),
            const Point2(1, 1),
            const Point2(0, 1),
          ),
          fellBack: path == '/slow',
        );
      });
      final future = seeder.seedBatch(const ['/slow', '/fast']);
      await Future<void>.delayed(Duration.zero);
      gateSlow.complete();
      final results = await future;
      expect(results[0].corners.tl.x, closeTo(0.9, 1e-6),
          reason: 'index 0 must be /slow');
      expect(results[1].corners.tl.x, closeTo(0.1, 1e-6),
          reason: 'index 1 must be /fast');
    });
  });

  group('ClassicalCornerSeed seedBatch — inherits the parallel default', () {
    test('empty input returns empty', () async {
      const seeder = ClassicalCornerSeed();
      final results = await seeder.seedBatch(const []);
      expect(results, isEmpty);
    });
  });
}

/// Minimal fake that routes every `seed` through an injected closure
/// and inherits the default `seedBatch` from [CornerSeeder] via
/// `extends`. Post-VI.7 the inherited default is a parallel
/// `Future.wait(imagePaths.map(seed))`; using `extends` is how
/// future seeders pick up that behaviour for free.
class _FakeSeeder extends CornerSeeder {
  _FakeSeeder(this.onSeed);
  final Future<SeedResult> Function(String path) onSeed;

  @override
  Future<SeedResult> seed(String imagePath) => onSeed(imagePath);
}
