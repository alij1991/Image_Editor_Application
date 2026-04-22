import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../../../core/logging/app_logger.dart';
import '../../../../engine/pipeline/edit_pipeline.dart';
import '../../data/project_store.dart';

final _log = AppLogger('AutoSave');

/// Debounced auto-save for the editor pipeline.
///
/// Extracted from `editor_session.dart` in Phase VII.1 — the session
/// used to own the timer and the dispose-flush path inline; pulling
/// them here lets the session read a single [schedule] / [flushAndDispose]
/// surface and leaves the debounce mechanics independently testable.
///
/// Contract (preserved from the pre-extraction session behaviour):
///   * Every [schedule] call resets the timer — fast successive calls
///     (a slider drag that commits once per delta) collapse to one
///     disk write at the end of the burst.
///   * The scheduled save is fire-and-forget; `ProjectStore.save`
///     already swallows IO errors, but we still wrap in try/catch so
///     future store impls can't crash the editor from the debounce
///     callback.
///   * After [flushAndDispose] nothing more runs. Subsequent
///     [schedule] calls are no-ops, the pending timer is cancelled,
///     and a final `save` is issued with whatever pipeline the caller
///     passes (the session feeds `historyManager.currentPipeline` so
///     the authoritative committed state wins over any in-flight
///     debounced intermediate).
class AutoSaveController {
  AutoSaveController({
    required this.sourcePath,
    required this.projectStore,
    Duration debounce = const Duration(milliseconds: 600),
  }) : _debounce = debounce;

  final String sourcePath;
  final ProjectStore projectStore;
  final Duration _debounce;

  Timer? _timer;
  bool _disposed = false;

  /// Number of times [_save] has actually reached [ProjectStore.save].
  /// Used by tests to assert debounce collapsed N schedules into 1 save.
  @visibleForTesting
  int debugSaveCallCount = 0;

  /// Number of times [_save] swallowed a thrown IO failure. Tests use
  /// this to assert the controller doesn't rethrow.
  @visibleForTesting
  int debugIoFailureCount = 0;

  /// Request a save `debounce` after this call. Successive calls reset
  /// the timer. No-op after [flushAndDispose].
  void schedule(EditPipeline pipeline) {
    if (_disposed) return;
    _timer?.cancel();
    _timer = Timer(_debounce, () {
      if (_disposed) return;
      unawaited(_save(pipeline));
    });
  }

  Future<void> _save(EditPipeline pipeline) async {
    try {
      await projectStore.save(
        sourcePath: sourcePath,
        pipeline: pipeline,
      );
      debugSaveCallCount++;
    } catch (e, st) {
      debugIoFailureCount++;
      _log.w('auto-save failed', {'error': e.toString()});
      _log.e('auto-save trace', error: e, stackTrace: st);
    }
  }

  /// Cancel any pending save and flush one final write. Meant to be
  /// called from the owning session's dispose() so the user's last
  /// edit isn't lost to an in-flight debounce timer that never fires.
  ///
  /// Idempotent — calling twice doesn't double-save.
  Future<void> flushAndDispose(EditPipeline finalPipeline) async {
    if (_disposed) return;
    _disposed = true;
    _timer?.cancel();
    _timer = null;
    await _save(finalPipeline);
  }

  /// True once [flushAndDispose] has started. After this returns true
  /// every [schedule] call is a no-op.
  @visibleForTesting
  bool get isDisposed => _disposed;

  /// True while a scheduled write is still pending. Flips to false as
  /// soon as the timer fires (or is cancelled).
  @visibleForTesting
  bool get hasPendingSave => _timer?.isActive ?? false;
}
