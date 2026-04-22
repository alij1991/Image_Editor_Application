import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';

import '../logging/app_logger.dart';

final _log = AppLogger('ImageCacheWatchdog');

/// Phase V.4: polls [isNearBudget] every [framesPerCheck] frames and
/// fires [onPurge] when the predicate is true on
/// [consecutiveWarningsNeeded] consecutive checks.
///
/// Wired by bootstrap against `ImageCachePolicy.nearBudget` +
/// `ImageCachePolicy.purge`, so the app responds to sustained image
/// cache pressure (Flutter issue #178264 — the Impeller GPU balloon
/// symptom). Using "two consecutive hits" as the trigger filters
/// out the single-frame spike of e.g. opening a large preset strip
/// briefly pushing over the warning band.
///
/// ## Why a frame-polled watchdog and not didHaveMemoryPressure
///
/// The OS-level signal only fires in critical memory conditions
/// (iOS memory warnings, Android `onTrimMemory`). By the time that
/// fires the editor already risks the kill. This watchdog responds
/// to a softer, earlier signal — "image cache crossed 75 % of its
/// OWN budget" — so eviction lands before the OS ever intervenes.
///
/// ## Testing shape
///
/// The watchdog takes function closures rather than a concrete
/// `ImageCachePolicy` so tests inject controlled predicates without
/// having to touch `PaintingBinding.instance.imageCache`. The
/// `@visibleForTesting advanceOneCheck()` method is the single
/// cycle of the state machine — tests drive it directly and bypass
/// the scheduler entirely.
class ImageCacheWatchdog {
  ImageCacheWatchdog({
    required this.isNearBudget,
    required this.onPurge,
    this.framesPerCheck = 60,
    this.consecutiveWarningsNeeded = 2,
  })  : assert(framesPerCheck > 0),
        assert(consecutiveWarningsNeeded > 0);

  /// Predicate — true when the image cache is in the warning band
  /// (`currentSizeBytes > 75% of maximumSizeBytes` in the default
  /// `ImageCachePolicy` impl).
  final bool Function() isNearBudget;

  /// Remediation — `PaintingBinding.instance.imageCache.clear() +
  /// clearLiveImages()` in the default wiring.
  final VoidCallback onPurge;

  /// How many frames between [isNearBudget] checks. Default 60 =
  /// once per second at 60 FPS. Higher values reduce overhead but
  /// delay response.
  final int framesPerCheck;

  /// How many consecutive checks must report "near budget" before
  /// [onPurge] fires. Default 2 keeps us honest against one-frame
  /// blips (entering a preset strip, loading a high-res LUT) that
  /// resolve themselves before the next check.
  final int consecutiveWarningsNeeded;

  int _frameCounter = 0;
  int _consecutiveWarnings = 0;
  bool _running = false;
  int _debugPurgeCount = 0;

  /// Begin the post-frame poll loop. Safe to call repeatedly — the
  /// second + call are a no-op. No-op at all if
  /// `SchedulerBinding.instance` isn't available yet (e.g.
  /// [bootstrap] fires before `WidgetsFlutterBinding.ensureInitialized()`
  /// has run).
  void start() {
    if (_running) return;
    _running = true;
    try {
      SchedulerBinding.instance.addPostFrameCallback(_onPostFrame);
      _log.i('started', {
        'framesPerCheck': framesPerCheck,
        'consecutiveWarningsNeeded': consecutiveWarningsNeeded,
      });
    } catch (e) {
      // SchedulerBinding not ready — disable and move on. Bootstrap
      // shouldn't fail because the watchdog can't register.
      _running = false;
      _log.w('start deferred — scheduler unavailable',
          {'error': e.toString()});
    }
  }

  /// Stop the poll loop. The post-frame callback chain checks
  /// [_running] and drops out on the next tick.
  void stop() {
    if (!_running) return;
    _running = false;
    _log.i('stopped', {'totalPurges': _debugPurgeCount});
  }

  /// One cycle of the watchdog state machine. Advances the
  /// consecutive-warning counter, fires [onPurge] if the threshold
  /// is crossed, and returns `true` iff [onPurge] was invoked.
  ///
  /// Exposed for tests so they can drive the transition table
  /// deterministically without spinning the scheduler.
  @visibleForTesting
  bool advanceOneCheck() {
    if (isNearBudget()) {
      _consecutiveWarnings++;
      _log.d('near-budget tick',
          {'consecutive': _consecutiveWarnings});
      if (_consecutiveWarnings >= consecutiveWarningsNeeded) {
        _log.w('purge threshold crossed — firing onPurge',
            {'consecutive': _consecutiveWarnings});
        onPurge();
        _consecutiveWarnings = 0;
        _debugPurgeCount++;
        return true;
      }
    } else if (_consecutiveWarnings != 0) {
      _log.d('pressure released — resetting counter',
          {'wasAt': _consecutiveWarnings});
      _consecutiveWarnings = 0;
    }
    return false;
  }

  /// Diagnostic: total number of [onPurge] invocations since
  /// [start]. Used by tests to pin the trigger contract and by
  /// bootstrap logs to surface long-term pressure patterns.
  int get debugPurgeCount => _debugPurgeCount;

  /// Diagnostic: current consecutive-warning streak.
  @visibleForTesting
  int get debugConsecutiveWarnings => _consecutiveWarnings;

  /// Diagnostic: whether the watchdog is currently polling.
  @visibleForTesting
  bool get debugIsRunning => _running;

  void _onPostFrame(Duration _) {
    if (!_running) return;
    _frameCounter++;
    if (_frameCounter >= framesPerCheck) {
      _frameCounter = 0;
      advanceOneCheck();
    }
    // Re-schedule for next frame. We don't branch on purge outcome
    // — another pressure event might arrive a second later and we
    // want to be ready for it.
    SchedulerBinding.instance.addPostFrameCallback(_onPostFrame);
  }
}
