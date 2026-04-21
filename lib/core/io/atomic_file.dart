import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show visibleForTesting;

import '../logging/app_logger.dart';

final _log = AppLogger('AtomicFile');

/// Atomically replace the contents of [target] so readers see either the
/// old content or the new content — never a truncated mix.
///
/// The write goes to `<target>.tmp` first, flushes bytes to disk
/// (`flush: true` → fsync on POSIX), then atomically renames the tmp
/// file over the target. `rename(2)` is a single syscall on POSIX so a
/// kill between flush and rename leaves the target untouched and a
/// stale `.tmp` sibling that the next save overwrites.
///
/// Guarantees:
/// - A kill / IO failure during the tmp write leaves [target] intact
///   (or absent when it was never saved).
/// - The parent directory of [target] is created if missing.
/// - Any pre-existing `.tmp` sibling is overwritten — stale tmp files
///   from prior crashes do not block a fresh save.
///
/// Not guaranteed:
/// - Cross-filesystem rename. Callers must keep [target] and `<target>.tmp`
///   on the same volume. `ProjectStore` and `ScanRepository` both write
///   inside `<AppDocs>/…` so this always holds on mobile.
/// - Two concurrent calls for the same [target]. The newer caller races
///   the older one on the same `.tmp` path; the rename that lands last
///   wins. For the debounced auto-save path this is fine (one writer
///   per path per tick), but callers that fan out saves to the same
///   file from multiple isolates must add their own mutex.
Future<void> atomicWriteString(File target, String content) async {
  await _atomicWrite(target, (tmp) => tmp.writeAsString(content, flush: true));
}

/// Bytes variant of [atomicWriteString]. Same atomicity guarantees.
Future<void> atomicWriteBytes(File target, Uint8List bytes) async {
  await _atomicWrite(target, (tmp) => tmp.writeAsBytes(bytes, flush: true));
}

/// Test-only hook that fires AFTER the tmp file has been written but
/// BEFORE the rename lands on the target.
///
/// Production leaves this `null`. Tests that want to simulate a crash
/// in the most error-prone window (post-flush, pre-rename) set it to a
/// callback that throws. [atomicWriteString] / [atomicWriteBytes] then
/// delete the tmp and rethrow, leaving the target in its prior state.
///
/// Tests MUST reset this to `null` in `tearDown` — it's global state.
@visibleForTesting
Future<void> Function()? debugHookBeforeRename;

Future<void> _atomicWrite(
  File target,
  Future<void> Function(File tmp) writer,
) async {
  final tmp = File('${target.path}.tmp');
  final parent = target.parent;
  if (!parent.existsSync()) {
    await parent.create(recursive: true);
  }
  try {
    await writer(tmp);
    final hook = debugHookBeforeRename;
    if (hook != null) await hook();
    await tmp.rename(target.path);
  } catch (e) {
    _log.w('atomicWrite failed; cleaning tmp', {
      'target': target.path,
      'error': e.toString(),
    });
    try {
      if (await tmp.exists()) await tmp.delete();
    } catch (_) {
      // Best-effort cleanup — orphan tmp will be overwritten on next save.
    }
    rethrow;
  }
}
