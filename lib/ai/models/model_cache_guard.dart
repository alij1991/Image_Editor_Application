import 'dart:async';

import '../../core/io/disk_stats.dart';
import '../../core/logging/app_logger.dart';

final _log = AppLogger('ModelCacheGuard');

/// Outcome of a single [ModelCacheGuard.runLowDiskCheck] call.
///
/// Exposed as a tagged union so callers (bootstrap log, future
/// UI surface) can distinguish "probe broken" from "enough space"
/// from "space reclaimed".
sealed class ModelCacheGuardOutcome {
  const ModelCacheGuardOutcome();
}

/// Host couldn't tell us free bytes — e.g. mobile impl missing,
/// `df` not on PATH. The guard did NOT evict.
final class GuardProbeUnavailable extends ModelCacheGuardOutcome {
  const GuardProbeUnavailable();
}

/// Probe succeeded; free space was at or above the threshold. No
/// eviction ran.
final class GuardAboveThreshold extends ModelCacheGuardOutcome {
  const GuardAboveThreshold({required this.freeBytes});
  final int freeBytes;
}

/// Probe succeeded, free space was low, and the guard invoked
/// `evictUntilUnder` which removed [removed] entries.
final class GuardEvicted extends ModelCacheGuardOutcome {
  const GuardEvicted({required this.freeBytes, required this.removed});
  final int freeBytes;
  final int removed;
}

/// Phase V.3 low-disk eviction scaffolding for [ModelCache].
///
/// Runs a free-space probe at bootstrap; if the host reports under
/// [freeSpaceThresholdBytes] (default 500 MB), shrinks the model
/// cache to at most [evictDownToBytes] (default 400 MB) by deleting
/// the oldest downloaded models. If the probe is unavailable (mobile
/// platform-channel not yet shipped, `df` missing, etc.), the guard
/// **skips eviction** rather than failing bootstrap.
///
/// ## Shape
///
/// The guard depends on [DiskStatsProvider] and a single
/// `evictUntilUnder` function. Production wires to
/// `DefaultDiskStatsProvider` + `modelCache.evictUntilUnder`. Tests
/// inject their own provider + a call-counting closure — no
/// sqflite mock required.
///
/// ## Why not a size-cap on its own?
///
/// A flat "cache must stay under X MB" policy would also work and
/// requires no platform probe. Phase V.3 shipped the free-space
/// scaffolding because the plan's spec named it specifically and
/// because "user's phone is nearly full" is the UX failure we
/// actually want to guard against. A hard size-cap remains a
/// good follow-up — mentioned in IMPROVEMENTS.md.
class ModelCacheGuard {
  ModelCacheGuard({
    required this.statsProvider,
    required this.evictUntilUnder,
    this.freeSpaceThresholdBytes = 500 * 1024 * 1024,
    this.evictDownToBytes = 400 * 1024 * 1024,
  });

  final DiskStatsProvider statsProvider;

  /// Injection point for [ModelCache.evictUntilUnder]. Takes the
  /// target byte ceiling, returns the number of entries removed.
  final Future<int> Function(int maxBytes) evictUntilUnder;

  /// When [DiskStats.freeBytes] drops below this value, the guard
  /// runs eviction. Default 500 MB (matches the PLAN V.3 spec).
  final int freeSpaceThresholdBytes;

  /// Target ceiling passed to [evictUntilUnder] once eviction
  /// triggers. Default 400 MB — leaves 100 MB of headroom under
  /// the threshold so the next check doesn't immediately re-fire.
  final int evictDownToBytes;

  /// Probe [probePath]'s volume, compare to [freeSpaceThresholdBytes],
  /// and if low, reclaim down to [evictDownToBytes]. Safe to call
  /// at any time — typical call site is bootstrap, after
  /// [ModelCache] is constructed.
  Future<ModelCacheGuardOutcome> runLowDiskCheck({
    required String probePath,
  }) async {
    final stats = await statsProvider.probe(forPath: probePath);
    if (stats == null) {
      _log.d('probe unavailable — skipping', {'path': probePath});
      return const GuardProbeUnavailable();
    }
    if (stats.freeBytes >= freeSpaceThresholdBytes) {
      _log.i('free space OK', {
        'path': probePath,
        'freeMB': stats.freeBytes ~/ (1024 * 1024),
        'thresholdMB': freeSpaceThresholdBytes ~/ (1024 * 1024),
      });
      return GuardAboveThreshold(freeBytes: stats.freeBytes);
    }
    _log.w('free space below threshold — evicting', {
      'freeMB': stats.freeBytes ~/ (1024 * 1024),
      'thresholdMB': freeSpaceThresholdBytes ~/ (1024 * 1024),
      'evictDownToMB': evictDownToBytes ~/ (1024 * 1024),
    });
    final removed = await evictUntilUnder(evictDownToBytes);
    _log.i('eviction complete', {
      'removed': removed,
      'freeBytesAtTrigger': stats.freeBytes,
    });
    return GuardEvicted(freeBytes: stats.freeBytes, removed: removed);
  }
}
