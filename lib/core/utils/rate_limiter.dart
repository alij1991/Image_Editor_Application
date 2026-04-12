import 'dart:async';

/// A throttle / rate limiter that guarantees a minimum interval between
/// callback invocations. Unlike [Debouncer], it calls on the leading edge
/// and then drops further calls until the window elapses.
///
/// Used by expensive paths — e.g. re-running a shader pass that cannot
/// keep up with full 60 fps slider updates.
class RateLimiter {
  RateLimiter({this.interval = const Duration(milliseconds: 33)});

  final Duration interval;
  DateTime? _lastFired;
  Timer? _trailingTimer;

  /// Try to invoke [callback] immediately. If the last call was within
  /// [interval], schedule a trailing call at the interval boundary instead.
  void run(void Function() callback) {
    final now = DateTime.now();
    final last = _lastFired;
    if (last == null || now.difference(last) >= interval) {
      _lastFired = now;
      _trailingTimer?.cancel();
      _trailingTimer = null;
      callback();
      return;
    }
    final remaining = interval - now.difference(last);
    _trailingTimer?.cancel();
    _trailingTimer = Timer(remaining, () {
      _lastFired = DateTime.now();
      _trailingTimer = null;
      callback();
    });
  }

  void cancel() {
    _trailingTimer?.cancel();
    _trailingTimer = null;
    _lastFired = null;
  }

  void dispose() => cancel();
}
