import 'package:flutter/foundation.dart';
import 'package:logger/logger.dart';

/// Per-component logger wrapper.
///
/// Every significant Dart file in the app owns a top-level
/// `final _log = AppLogger('ComponentName');` and calls
/// `_log.d/i/w/e(...)`. Messages are prefixed with the component name so
/// you can grep the console for a specific subsystem, e.g.
/// `flutter logs | grep '\[EditorSession\]'`.
///
/// Levels:
///   - `d` debug: fine-grained tracing (slider updates, frame timings).
///     Filtered out in release builds.
///   - `i` info: lifecycle (session start/close, undo/redo, image load).
///   - `w` warning: recoverable (cache near budget, permission denied,
///     fallback to CPU delegate).
///   - `e` error: unrecoverable (shader compile failure, image decode
///     failure, history overflow).
///
/// Optional structured `data` is rendered inline as a JSON-ish tail:
///   [EditorSession] updateBrightness {value: 0.32}
///
/// To change the global level at runtime (e.g. from a settings toggle),
/// assign to [AppLogger.level]. Defaults to `debug` in debug builds,
/// `warning` in release.
class AppLogger {
  AppLogger(this.component);

  final String component;

  /// Runtime-mutable global level. Read by every logger instance.
  static Level level = kReleaseMode ? Level.warning : Level.debug;

  /// Single shared underlying logger so timestamps / output are unified.
  static final Logger _backing = Logger(
    filter: _LevelFilter(),
    printer: PrettyPrinter(
      methodCount: 0,
      errorMethodCount: 8,
      lineLength: 100,
      colors: false,
      printEmojis: false,
      dateTimeFormat: DateTimeFormat.onlyTimeAndSinceStart,
    ),
  );

  void d(String message, [Object? data]) =>
      _backing.d('[$component] ${_format(message, data)}');

  void i(String message, [Object? data]) =>
      _backing.i('[$component] ${_format(message, data)}');

  void w(String message, [Object? data]) =>
      _backing.w('[$component] ${_format(message, data)}');

  void e(
    String message, {
    Object? error,
    StackTrace? stackTrace,
    Object? data,
  }) =>
      _backing.e(
        '[$component] ${_format(message, data)}',
        error: error,
        stackTrace: stackTrace,
      );

  String _format(String message, Object? data) {
    if (data == null) return message;
    return '$message $data';
  }
}

class _LevelFilter extends LogFilter {
  @override
  bool shouldLog(LogEvent event) {
    return event.level.index >= AppLogger.level.index;
  }
}
