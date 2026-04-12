import 'dart:async';

/// A leading/trailing debouncer for shader uniform updates.
///
/// The blueprint specifies a 16 ms debounce on slider events so parameter
/// changes coalesce to one per-frame update even when users drag a slider
/// with high input rates. Instances are cheap; use one per slider /
/// parameter.
class Debouncer {
  Debouncer({this.duration = const Duration(milliseconds: 16)});

  final Duration duration;
  Timer? _timer;

  /// Schedule [callback] to run after [duration] has elapsed with no new
  /// calls to [run]. If [run] is called again before the timer fires, the
  /// pending callback is replaced.
  void run(void Function() callback) {
    _timer?.cancel();
    _timer = Timer(duration, callback);
  }

  /// Cancel any pending callback.
  void cancel() {
    _timer?.cancel();
    _timer = null;
  }

  /// Immediately fire the pending callback, if any.
  void flush(void Function() callback) {
    if (_timer?.isActive ?? false) {
      _timer!.cancel();
      _timer = null;
      callback();
    }
  }

  void dispose() => cancel();
}
