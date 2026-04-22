import 'dart:async';
import 'dart:io';

import '../logging/app_logger.dart';

final _log = AppLogger('DiskStats');

/// Snapshot of the volume free / total bytes at the path a provider
/// was asked to probe.
///
/// Values are **unsigned 64-bit-ish** — some platforms return bytes
/// directly, others return kilobyte-blocks that we scale up.
class DiskStats {
  const DiskStats({required this.freeBytes, required this.totalBytes});

  final int freeBytes;
  final int totalBytes;

  Map<String, Object?> toLogMap() => {
        'freeBytes': freeBytes,
        'totalBytes': totalBytes,
        'freeMB': freeBytes ~/ (1024 * 1024),
        'totalMB': totalBytes ~/ (1024 * 1024),
      };
}

/// Query free / total bytes of the volume containing a given path.
///
/// There is no cross-platform Dart IO API for this. Mobile platforms
/// (iOS / Android) need a platform-channel bridge; flutter_test and
/// desktop can parse `df`. This interface is deliberately narrow so
/// (a) tests can inject a fixed-value fake and (b) a future
/// platform-channel impl drops in without touching the guard layer.
///
/// The contract is intentionally fault-tolerant: returning `null`
/// signals "probe unavailable on this host right now", and the
/// guard treats that as "skip check, don't fail bootstrap."
abstract class DiskStatsProvider {
  Future<DiskStats?> probe({required String forPath});
}

/// Best-effort implementation that uses `Process.run('df', ['-k', path])`
/// on macOS / Linux (development + CI). Returns `null` on every other
/// host — iOS / Android / Windows need a platform-channel bridge that
/// is tracked as a follow-up in `docs/IMPROVEMENTS.md`.
///
/// The real payoff from Phase V.3 is the **scaffolding**: the guard,
/// the thresholds, and the Model Manager "Free up space" button all
/// ship working today; swapping in a mobile probe later is a
/// drop-in.
class DefaultDiskStatsProvider implements DiskStatsProvider {
  const DefaultDiskStatsProvider();

  @override
  Future<DiskStats?> probe({required String forPath}) async {
    if (!(Platform.isMacOS || Platform.isLinux)) {
      _log.d('probe unavailable on this platform', {
        'os': Platform.operatingSystem,
        'path': forPath,
      });
      return null;
    }
    try {
      // `df -k <path>` reports 1024-byte blocks — every POSIX df
      // supports the flag uniformly. We intentionally don't use
      // `-P` / `-h` since parsing human-readable units is fragile.
      final result = await Process.run('df', ['-k', forPath]);
      if (result.exitCode != 0) {
        _log.w('df non-zero exit', {
          'exit': result.exitCode,
          'stderr': result.stderr.toString(),
        });
        return null;
      }
      final parsed = parseDfOutput(result.stdout.toString());
      if (parsed == null) {
        _log.w('df output unparseable', {'stdout': result.stdout.toString()});
        return null;
      }
      _log.d('probe', {'path': forPath, ...parsed.toLogMap()});
      return parsed;
    } catch (e, st) {
      _log.w('probe threw — treating as unavailable',
          {'error': e.toString(), 'path': forPath});
      _log.d('probe error trace', {'trace': st.toString()});
      return null;
    }
  }
}

/// Parse `df -k` output into [DiskStats]. Exposed for unit testing
/// because the real [Process.run] path is platform-specific and we
/// want the column math pinned independently.
///
/// Example input (GNU `df -k`):
/// ```
/// Filesystem       1K-blocks      Used Available Use% Mounted on
/// /dev/disk1s1     488555536 210123456 271000000  44% /
/// ```
///
/// Output `DiskStats.freeBytes` = `271000000 * 1024`,
/// `totalBytes` = `488555536 * 1024`.
///
/// Returns `null` when the output can't be parsed — malformed /
/// unexpected column order / empty.
DiskStats? parseDfOutput(String stdout) {
  final lines = stdout.trim().split('\n');
  if (lines.length < 2) return null;
  // The data row is the last non-empty line so we don't assume
  // exactly two lines (BSD `df` can wrap long filesystem names onto
  // a second line on some hosts — when that happens, the
  // filesystem name sits on line N-1 and the numeric columns
  // land on line N without a filesystem column of their own).
  final dataLine = lines.last.trim();
  final cols = dataLine.split(RegExp(r'\s+'));
  if (cols.length < 4) return null;
  // Columns on both GNU and BSD df -k:
  //   0: Filesystem
  //   1: 1K-blocks      (total)
  //   2: Used
  //   3: Available       (free)
  // When the filesystem name wraps to the previous line, the
  // filesystem column is missing so every index shifts left by 1.
  // Detect the wrap by checking whether cols[0] parses as an int.
  final firstIsNumeric = int.tryParse(cols[0]) != null;
  final totalIdx = firstIsNumeric ? 0 : 1;
  final availableIdx = firstIsNumeric ? 2 : 3;
  if (cols.length <= availableIdx) return null;
  final total = int.tryParse(cols[totalIdx]);
  final available = int.tryParse(cols[availableIdx]);
  if (total == null || available == null) return null;
  return DiskStats(
    freeBytes: available * 1024,
    totalBytes: total * 1024,
  );
}
