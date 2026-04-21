import 'dart:async';

import 'package:flutter_test/flutter_test.dart';

import 'package:image_editor/core/async/generation_guard.dart';

/// Behaviour tests for the Phase IV.4 `GenerationGuard` helper — the
/// shared async-result commit guard that replaces three bespoke
/// race-guard Maps across `ScannerNotifier` (`_processGen`) and
/// `EditorSession` (curve-LUT bake + cutout hydrate).
///
/// Tests are framed as the three canonical patterns that each call
/// site reduces to:
///   1. rapid same-key taps — only the newest result commits.
///   2. single-slot bake — the latest of several concurrent workers
///      wins; older ones self-drop.
///   3. delete-and-recreate — `forget` cuts in-flight ops loose and
///      lets fresh begins restart from 1.
///
/// Every scenario uses real `Future` / `Completer` interleavings
/// rather than mocking so the guard is exercised the same way
/// production will use it.
void main() {
  group('GenerationGuard — primitives', () {
    test('begin yields 1 for an unseen key and increments monotonically',
        () {
      final guard = GenerationGuard<String>();
      expect(guard.begin('a'), 1);
      expect(guard.begin('a'), 2);
      expect(guard.begin('a'), 3);
    });

    test('keys are independent', () {
      final guard = GenerationGuard<String>();
      expect(guard.begin('a'), 1);
      expect(guard.begin('b'), 1);
      expect(guard.begin('a'), 2);
      expect(guard.begin('b'), 2);
      expect(guard.begin('c'), 1);
    });

    test('isLatest returns true only for the most recent stamp', () {
      final guard = GenerationGuard<String>();
      final first = guard.begin('k');
      final second = guard.begin('k');
      expect(guard.isLatest('k', first), isFalse);
      expect(guard.isLatest('k', second), isTrue);
    });

    test('isLatest is false for an untracked key', () {
      final guard = GenerationGuard<String>();
      expect(guard.isLatest('never-begun', 1), isFalse);
    });

    test('isLatest is false for stamp=0 on an untracked key', () {
      // Guards against a caller that "thinks" 0 means "no op yet".
      // The [begin] counter starts at 1, so 0 never matches anything.
      final guard = GenerationGuard<String>();
      expect(guard.isLatest('k', 0), isFalse);
      guard.begin('k'); // Issues 1.
      expect(guard.isLatest('k', 0), isFalse);
    });

    test('forget drops tracking and next begin restarts at 1', () {
      final guard = GenerationGuard<String>();
      guard.begin('k');
      guard.begin('k');
      expect(guard.generationOf('k'), 2);
      guard.forget('k');
      expect(guard.generationOf('k'), 0);
      expect(guard.begin('k'), 1);
    });

    test('forget on an unknown key is a no-op', () {
      final guard = GenerationGuard<String>();
      guard.forget('not-there');
      expect(guard.trackedKeyCount, 0);
    });

    test('clear drops all tracked keys', () {
      final guard = GenerationGuard<String>();
      guard.begin('a');
      guard.begin('b');
      guard.begin('c');
      expect(guard.trackedKeyCount, 3);
      guard.clear();
      expect(guard.trackedKeyCount, 0);
      expect(guard.isLatest('a', 1), isFalse);
    });
  });

  group('GenerationGuard — integer keys', () {
    test('works with int keys too', () {
      final guard = GenerationGuard<int>();
      final s1 = guard.begin(42);
      final s2 = guard.begin(42);
      expect(guard.isLatest(42, s1), isFalse);
      expect(guard.isLatest(42, s2), isTrue);
    });
  });

  group('GenerationGuard — async commit patterns', () {
    // Simulates the ScannerNotifier._processGen scenario: rapid
    // same-key taps where only the newest result is allowed to
    // commit. Uses Completers to control the order deterministically.
    test('rapid same-key taps: only the newest commit survives',
        () async {
      final guard = GenerationGuard<String>();
      final log = <String>[];

      Future<void> asyncWorker(String label, Completer<void> gate) async {
        final stamp = guard.begin('page-1');
        await gate.future;
        if (!guard.isLatest('page-1', stamp)) {
          log.add('drop:$label');
          return;
        }
        log.add('commit:$label');
      }

      final a = Completer<void>();
      final b = Completer<void>();
      final c = Completer<void>();
      final futures = <Future<void>>[
        asyncWorker('A', a),
        asyncWorker('B', b),
        asyncWorker('C', c),
      ];
      // Complete out of order — A first, then C, then B. Only C (the
      // last one to call begin) should commit.
      a.complete();
      await Future.delayed(Duration.zero);
      c.complete();
      await Future.delayed(Duration.zero);
      b.complete();
      await Future.wait(futures);

      expect(log, containsAllInOrder(['drop:A', 'commit:C', 'drop:B']));
      // Only one 'commit:' entry, and it's the last [begin] caller.
      expect(log.where((e) => e.startsWith('commit:')).length, 1);
    });

    test('different keys do not interfere — each commits its own result',
        () async {
      final guard = GenerationGuard<String>();
      final committed = <String>[];

      Future<void> asyncWorker(String key) async {
        final stamp = guard.begin(key);
        await Future.delayed(Duration.zero);
        if (guard.isLatest(key, stamp)) committed.add(key);
      }

      await Future.wait([
        asyncWorker('page-1'),
        asyncWorker('page-2'),
        asyncWorker('page-3'),
      ]);
      expect(committed, containsAll(['page-1', 'page-2', 'page-3']));
    });

    // Simulates the EditorSession._bakeCurveLut scenario: a single
    // slot (conceptually `'curve'`), many authorings over time.
    test('single-slot bake: latest begin wins, all earlier self-drop',
        () async {
      final guard = GenerationGuard<String>();
      final completers = <int, Completer<void>>{};
      final committed = <int>[];

      Future<void> bake(int id) async {
        final stamp = guard.begin('curve');
        completers[id] = Completer<void>();
        await completers[id]!.future;
        if (guard.isLatest('curve', stamp)) committed.add(id);
      }

      // Start 5 bakes — each one bumps the generation.
      final futures = [
        for (var i = 0; i < 5; i++) bake(i),
      ];
      // Let all bakes hit their await.
      await Future.delayed(Duration.zero);
      // Complete all in the ORIGINAL order — only the last-started
      // (id 4) should survive the commit guard.
      for (var i = 0; i < 5; i++) {
        completers[i]!.complete();
        await Future.delayed(Duration.zero);
      }
      await Future.wait(futures);
      expect(committed, [4]);
    });

    // Simulates the EditorSession._hydrateCutouts + _cacheCutoutImage
    // scenario: during an async decode, a fresh AI segmentation lands
    // for the same layer. The guard should discard the decode result.
    test('decode vs cache: cache-bump causes the decode to self-drop',
        () async {
      final guard = GenerationGuard<String>();
      final events = <String>[];

      Future<void> decodeHydrate() async {
        final stamp = guard.begin('layer-A');
        // Yield to let the synchronous cache-bump jump in first.
        await Future.delayed(Duration.zero);
        if (!guard.isLatest('layer-A', stamp)) {
          events.add('decode:drop');
          return;
        }
        events.add('decode:commit');
      }

      final f = decodeHydrate();
      // Synchronous AI-cache path lands on the same key while the
      // decode is mid-await. Bumping the counter supersedes the
      // in-flight decode.
      final stamp = guard.begin('layer-A');
      events.add('cache:commit:$stamp');
      await f;
      expect(events, ['cache:commit:2', 'decode:drop']);
    });

    test('forget while in-flight makes the stale worker self-drop',
        () async {
      // Models the "layer deleted mid-decode" case: forget() cuts the
      // in-flight op loose, so its eventual isLatest() check returns
      // false and the result is discarded.
      final guard = GenerationGuard<String>();
      bool committed = false;

      final stamp = guard.begin('layer-X');
      final completer = Completer<void>();

      final future = () async {
        await completer.future;
        if (guard.isLatest('layer-X', stamp)) committed = true;
      }();

      guard.forget('layer-X'); // Simulates layer deletion.
      completer.complete();
      await future;
      expect(committed, isFalse);
    });

    test('clear mid-flight drops every stale worker', () async {
      // Models ScannerNotifier.clear() — tearing down the session
      // should drop every async result still on the wire.
      final guard = GenerationGuard<String>();
      final survivors = <String>[];

      Future<void> worker(String key, Completer<void> gate) async {
        final stamp = guard.begin(key);
        await gate.future;
        if (guard.isLatest(key, stamp)) survivors.add(key);
      }

      final gates = List.generate(3, (_) => Completer<void>());
      final futures = [
        worker('a', gates[0]),
        worker('b', gates[1]),
        worker('c', gates[2]),
      ];
      guard.clear();
      for (final g in gates) {
        g.complete();
      }
      await Future.wait(futures);
      expect(survivors, isEmpty);
    });
  });
}
