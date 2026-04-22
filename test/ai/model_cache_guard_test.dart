import 'package:flutter_test/flutter_test.dart';

import 'package:image_editor/ai/models/model_cache_guard.dart';
import 'package:image_editor/core/io/disk_stats.dart';

/// Phase V.3 tests for the [ModelCacheGuard] eviction trigger.
///
/// The guard is the thin policy layer between a [DiskStatsProvider]
/// and [ModelCache.evictUntilUnder]. These tests drive it with a
/// fake provider + a call-recording closure — no sqflite, no
/// real filesystem, no bootstrap boot.
void main() {
  const mb = 1024 * 1024;

  group('ModelCacheGuard.runLowDiskCheck', () {
    test('free space above threshold → no eviction', () async {
      int evictCalls = 0;
      final guard = ModelCacheGuard(
        statsProvider: _FakeStatsProvider(
          freeBytes: 800 * mb, // well above 500 MB
          totalBytes: 128 * 1024 * mb,
        ),
        evictUntilUnder: (target) async {
          evictCalls++;
          return 0;
        },
      );
      final outcome = await guard.runLowDiskCheck(probePath: '/data');
      expect(evictCalls, 0);
      expect(outcome, isA<GuardAboveThreshold>());
      expect((outcome as GuardAboveThreshold).freeBytes, 800 * mb);
    });

    test('free space at the threshold is NOT low — no eviction', () async {
      int evictCalls = 0;
      final guard = ModelCacheGuard(
        statsProvider: _FakeStatsProvider(
          freeBytes: 500 * mb, // exact threshold
          totalBytes: 64 * 1024 * mb,
        ),
        evictUntilUnder: (target) async {
          evictCalls++;
          return 0;
        },
      );
      final outcome = await guard.runLowDiskCheck(probePath: '/data');
      expect(evictCalls, 0);
      expect(outcome, isA<GuardAboveThreshold>());
    });

    test('free space below threshold → evicts down to evictDownToBytes',
        () async {
      int evictCalls = 0;
      int? evictTarget;
      final guard = ModelCacheGuard(
        statsProvider: _FakeStatsProvider(
          freeBytes: 200 * mb, // well under 500 MB
          totalBytes: 16 * 1024 * mb,
        ),
        evictUntilUnder: (target) async {
          evictCalls++;
          evictTarget = target;
          return 3;
        },
      );
      final outcome = await guard.runLowDiskCheck(probePath: '/data');
      expect(evictCalls, 1);
      expect(evictTarget, 400 * mb,
          reason: 'default evictDownToBytes = 400 MB');
      expect(outcome, isA<GuardEvicted>());
      final evicted = outcome as GuardEvicted;
      expect(evicted.removed, 3);
      expect(evicted.freeBytes, 200 * mb);
    });

    test('custom thresholds are honoured', () async {
      int? evictTarget;
      final guard = ModelCacheGuard(
        statsProvider: _FakeStatsProvider(
          freeBytes: 50 * mb,
          totalBytes: 1024 * mb,
        ),
        evictUntilUnder: (t) async {
          evictTarget = t;
          return 1;
        },
        freeSpaceThresholdBytes: 100 * mb,
        evictDownToBytes: 64 * mb,
      );
      final outcome = await guard.runLowDiskCheck(probePath: '/a');
      expect(outcome, isA<GuardEvicted>());
      expect(evictTarget, 64 * mb);
    });

    test('probe returning null → skip eviction safely', () async {
      int evictCalls = 0;
      final guard = ModelCacheGuard(
        statsProvider: _FakeStatsProvider.unavailable(),
        evictUntilUnder: (target) async {
          evictCalls++;
          return 0;
        },
      );
      final outcome = await guard.runLowDiskCheck(probePath: '/data');
      expect(evictCalls, 0,
          reason: 'no probe = no eviction — never risk deleting blind');
      expect(outcome, isA<GuardProbeUnavailable>());
    });

    test('eviction returning 0 is still a GuardEvicted outcome', () async {
      // Edge case: free-space probe said "low" but evictUntilUnder
      // reports 0 removals (maybe the cache was already small and
      // the disk pressure is external). Guard still reports what
      // happened rather than pretending the trigger didn't fire.
      final guard = ModelCacheGuard(
        statsProvider: _FakeStatsProvider(
          freeBytes: 300 * mb,
          totalBytes: 32 * 1024 * mb,
        ),
        evictUntilUnder: (t) async => 0,
      );
      final outcome = await guard.runLowDiskCheck(probePath: '/a');
      expect(outcome, isA<GuardEvicted>());
      expect((outcome as GuardEvicted).removed, 0);
    });

    test('probePath is forwarded to the provider verbatim', () async {
      String? received;
      final guard = ModelCacheGuard(
        statsProvider: _RecordingStatsProvider((p) {
          received = p;
          return const DiskStats(freeBytes: 1024 * mb, totalBytes: 2048 * mb);
        }),
        evictUntilUnder: (t) async => 0,
      );
      await guard.runLowDiskCheck(probePath: '/expected/path');
      expect(received, '/expected/path');
    });
  });

  group('parseDfOutput', () {
    test('parses GNU df -k single-line output', () {
      // Typical Linux `df -k /path` format.
      const stdout = '''
Filesystem     1K-blocks      Used Available Use% Mounted on
/dev/sda1       488555536 210123456 271000000  44% /
''';
      final stats = parseDfOutput(stdout);
      expect(stats, isNotNull);
      expect(stats!.totalBytes, 488555536 * 1024);
      expect(stats.freeBytes, 271000000 * 1024);
    });

    test('parses BSD/macOS df -k output', () {
      // `df -k` on macOS: same column order, longer filesystem name.
      const stdout = '''
Filesystem       1024-blocks      Used Available Capacity iused ifree %iused  Mounted on
/dev/disk1s1s1    488555536 210123456 271000000    44% 1234567 891011   58%   /
''';
      final stats = parseDfOutput(stdout);
      expect(stats, isNotNull);
      expect(stats!.freeBytes, 271000000 * 1024);
      expect(stats.totalBytes, 488555536 * 1024);
    });

    test('returns null on empty input', () {
      expect(parseDfOutput(''), isNull);
    });

    test('returns null on header-only input', () {
      const stdout = 'Filesystem     1K-blocks      Used Available Use% Mounted on\n';
      expect(parseDfOutput(stdout), isNull);
    });

    test('returns null on malformed columns', () {
      const stdout = '''
Filesystem     1K-blocks
/dev/sda1      garbage
''';
      expect(parseDfOutput(stdout), isNull);
    });

    test('uses the last non-empty line (BSD wrap case)', () {
      // Some BSD df wraps the filesystem name onto a second line when
      // it's long; parsing must still succeed by taking the last line.
      const stdout = '''
Filesystem                 1K-blocks      Used Available Use% Mounted on
/dev/really/long/path
                           488555536 210123456 271000000  44% /
''';
      final stats = parseDfOutput(stdout);
      expect(stats, isNotNull);
      expect(stats!.freeBytes, 271000000 * 1024);
    });
  });
}

/// Fake provider that returns a fixed value (or null for "unavailable").
class _FakeStatsProvider implements DiskStatsProvider {
  _FakeStatsProvider({
    required int freeBytes,
    required int totalBytes,
  }) : _stats = DiskStats(freeBytes: freeBytes, totalBytes: totalBytes);

  _FakeStatsProvider.unavailable() : _stats = null;

  final DiskStats? _stats;

  @override
  Future<DiskStats?> probe({required String forPath}) async => _stats;
}

/// Fake provider that routes each probe call through a closure so the
/// test can assert on the forwarded path.
class _RecordingStatsProvider implements DiskStatsProvider {
  _RecordingStatsProvider(this._fn);

  final DiskStats Function(String path) _fn;

  @override
  Future<DiskStats?> probe({required String forPath}) async => _fn(forPath);
}
