import 'package:flutter_test/flutter_test.dart';

import 'package:image_editor/core/memory/image_cache_watchdog.dart';

/// Phase V.4 tests for [ImageCacheWatchdog] — the `nearBudget →
/// two consecutive hits → purge` state machine.
///
/// Tests drive `advanceOneCheck()` directly rather than spinning
/// the scheduler, so the transition table is deterministic and
/// the test never relies on `addPostFrameCallback` firing.
void main() {
  // Lifecycle tests call `start()` which registers a post-frame
  // callback through `SchedulerBinding.instance`. Without the test
  // binding initialised, the instance throws and the watchdog's
  // defensive catch flips `_running` back to false — making the
  // lifecycle tests read "false" instead of "true". Initializing
  // the binding up front avoids that.
  TestWidgetsFlutterBinding.ensureInitialized();

  group('ImageCacheWatchdog.advanceOneCheck', () {
    test('single near-budget tick does NOT purge', () {
      int purges = 0;
      final w = ImageCacheWatchdog(
        isNearBudget: () => true,
        onPurge: () => purges++,
      );
      final fired = w.advanceOneCheck();
      expect(fired, isFalse);
      expect(purges, 0);
      expect(w.debugPurgeCount, 0);
      expect(w.debugConsecutiveWarnings, 1);
    });

    test('two consecutive near-budget ticks DO purge', () {
      int purges = 0;
      final w = ImageCacheWatchdog(
        isNearBudget: () => true,
        onPurge: () => purges++,
      );
      expect(w.advanceOneCheck(), isFalse);
      expect(w.advanceOneCheck(), isTrue);
      expect(purges, 1);
      expect(w.debugPurgeCount, 1);
      expect(w.debugConsecutiveWarnings, 0,
          reason: 'counter resets after purge fires');
    });

    test('pressure released between ticks resets the counter', () {
      bool near = true;
      int purges = 0;
      final w = ImageCacheWatchdog(
        isNearBudget: () => near,
        onPurge: () => purges++,
      );
      // Hit 1: near.
      w.advanceOneCheck();
      expect(w.debugConsecutiveWarnings, 1);
      // Pressure releases.
      near = false;
      w.advanceOneCheck();
      expect(w.debugConsecutiveWarnings, 0,
          reason: 'non-near tick resets the streak');
      // Pressure returns for one tick.
      near = true;
      w.advanceOneCheck();
      expect(w.debugConsecutiveWarnings, 1);
      expect(purges, 0,
          reason: 'the streak after release is only 1 long, below the '
              '2-hit threshold');
    });

    test('sustained pressure across three ticks fires once at tick 2',
        () {
      int purges = 0;
      final w = ImageCacheWatchdog(
        isNearBudget: () => true,
        onPurge: () => purges++,
      );
      expect(w.advanceOneCheck(), isFalse); // consec=1
      expect(w.advanceOneCheck(), isTrue); // consec=2 → purge, reset 0
      expect(w.advanceOneCheck(), isFalse); // consec=1 again
      expect(purges, 1,
          reason: 'a single purge per consecutive streak, not a rapid-fire '
              'flood');
    });

    test('sustained pressure for 4 ticks fires at tick 2 AND tick 4', () {
      int purges = 0;
      final w = ImageCacheWatchdog(
        isNearBudget: () => true,
        onPurge: () => purges++,
      );
      w.advanceOneCheck(); // consec=1
      w.advanceOneCheck(); // consec=2 → purge (1), reset
      w.advanceOneCheck(); // consec=1
      w.advanceOneCheck(); // consec=2 → purge (2), reset
      expect(purges, 2);
      expect(w.debugPurgeCount, 2);
    });

    test('non-near from cold start is a no-op (not a reset storm)', () {
      int purges = 0;
      int isNearCalls = 0;
      final w = ImageCacheWatchdog(
        isNearBudget: () {
          isNearCalls++;
          return false;
        },
        onPurge: () => purges++,
      );
      w.advanceOneCheck();
      w.advanceOneCheck();
      w.advanceOneCheck();
      expect(purges, 0);
      expect(w.debugConsecutiveWarnings, 0);
      expect(isNearCalls, 3);
    });

    test('custom consecutiveWarningsNeeded = 1 fires on first hit', () {
      int purges = 0;
      final w = ImageCacheWatchdog(
        isNearBudget: () => true,
        onPurge: () => purges++,
        consecutiveWarningsNeeded: 1,
      );
      expect(w.advanceOneCheck(), isTrue);
      expect(purges, 1);
    });

    test('custom consecutiveWarningsNeeded = 3 requires three hits', () {
      int purges = 0;
      final w = ImageCacheWatchdog(
        isNearBudget: () => true,
        onPurge: () => purges++,
        consecutiveWarningsNeeded: 3,
      );
      expect(w.advanceOneCheck(), isFalse); // consec=1
      expect(w.advanceOneCheck(), isFalse); // consec=2
      expect(w.advanceOneCheck(), isTrue); // consec=3 → purge
      expect(purges, 1);
    });

    test('isNearBudget is invoked every tick (never short-circuited)', () {
      int isNearCalls = 0;
      final w = ImageCacheWatchdog(
        isNearBudget: () {
          isNearCalls++;
          return false;
        },
        onPurge: () {},
      );
      for (int i = 0; i < 10; i++) {
        w.advanceOneCheck();
      }
      expect(isNearCalls, 10,
          reason: 'watchdog must poll every tick; a lazy-short-circuit '
              'would miss an incoming pressure event');
    });

    test('constructor rejects framesPerCheck <= 0', () {
      expect(
        () => ImageCacheWatchdog(
          isNearBudget: () => false,
          onPurge: () {},
          framesPerCheck: 0,
        ),
        throwsA(isA<AssertionError>()),
      );
    });

    test('constructor rejects consecutiveWarningsNeeded <= 0', () {
      expect(
        () => ImageCacheWatchdog(
          isNearBudget: () => false,
          onPurge: () {},
          consecutiveWarningsNeeded: 0,
        ),
        throwsA(isA<AssertionError>()),
      );
    });
  });

  group('ImageCacheWatchdog lifecycle', () {
    test('start() is idempotent', () {
      final w = ImageCacheWatchdog(
        isNearBudget: () => false,
        onPurge: () {},
      );
      w.start();
      w.start();
      expect(w.debugIsRunning, isTrue);
    });

    test('stop() sets debugIsRunning to false', () {
      final w = ImageCacheWatchdog(
        isNearBudget: () => false,
        onPurge: () {},
      );
      w.start();
      expect(w.debugIsRunning, isTrue);
      w.stop();
      expect(w.debugIsRunning, isFalse);
    });

    test('stop() before start() is a safe no-op', () {
      final w = ImageCacheWatchdog(
        isNearBudget: () => false,
        onPurge: () {},
      );
      w.stop(); // should not throw
      expect(w.debugIsRunning, isFalse);
    });
  });
}
