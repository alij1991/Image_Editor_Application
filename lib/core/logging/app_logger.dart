import 'dart:developer' as developer;

import 'package:flutter/foundation.dart';
import 'package:logger/logger.dart' show Level;

/// Per-component logger wrapper.
///
/// Every significant Dart file owns a `final _log = AppLogger('Name');`.
/// Output is a single line per event:
///
///   13:42:33.591 D Name msg key=val key=val
///
/// One-character level (D/I/W/E), no box decorations, structured data
/// rendered as `key=value` so it greps well. Errors append the message
/// then a single-line `ERR: <type>: <message>`; full stack traces only
/// surface in debug builds.
///
/// Levels:
///   - `d` debug — fine-grained (slider drag, frame). Off in release.
///   - `i` info — lifecycle (session, undo, image load).
///   - `w` warn — recoverable (cache pressure, permission denied).
///   - `e` error — unrecoverable (shader compile, decode failure).
///
/// To change at runtime: assign to [AppLogger.level]. Defaults to
/// `info` in debug builds (verbose `debug` events stay quiet so the
/// console is readable), `warning` in release.
class AppLogger {
  AppLogger(this.component);

  final String component;

  /// Runtime-mutable global level. Read by every logger instance.
  static Level level = kReleaseMode ? Level.warning : Level.info;

  static const String _kReset = '\x1B[0m';
  static const String _kGray = '\x1B[90m';
  static const String _kYellow = '\x1B[33m';
  static const String _kRed = '\x1B[31m';
  static const bool _kColor = !kReleaseMode;

  void d(String message, [Object? data]) => _log(Level.debug, message, data);
  void i(String message, [Object? data]) => _log(Level.info, message, data);
  void w(String message, [Object? data]) => _log(Level.warning, message, data);

  void e(
    String message, {
    Object? error,
    StackTrace? stackTrace,
    Object? data,
  }) {
    if (level.index > Level.error.index) return;
    final line = _buildLine(Level.error, message, data, error);
    developer.log(
      line,
      name: '',
      level: 1000,
      error: error,
      // Only ship the trace in debug — release logs stay small.
      stackTrace: kReleaseMode ? null : stackTrace,
    );
  }

  void _log(Level lvl, String message, Object? data) {
    if (lvl.index < level.index) return;
    developer.log(
      _buildLine(lvl, message, data, null),
      name: '',
      level: _devLevel(lvl),
    );
  }

  String _buildLine(Level lvl, String message, Object? data, Object? error) {
    final ts = _ts(DateTime.now());
    final tag = _tag(lvl);
    final body = data == null ? message : '$message ${_fmtData(data)}';
    final base = '$ts $tag $component $body';
    if (error == null) return base;
    return '$base | ERR: ${error.runtimeType}: $error';
  }

  static String _ts(DateTime now) {
    String two(int v) => v.toString().padLeft(2, '0');
    String three(int v) => v.toString().padLeft(3, '0');
    return '${two(now.hour)}:${two(now.minute)}:${two(now.second)}.${three(now.millisecond)}';
  }

  static String _tag(Level lvl) {
    switch (lvl) {
      case Level.debug:
        return _kColor ? '${_kGray}D$_kReset' : 'D';
      case Level.info:
        return 'I';
      case Level.warning:
        return _kColor ? '${_kYellow}W$_kReset' : 'W';
      case Level.error:
        return _kColor ? '${_kRed}E$_kReset' : 'E';
      default:
        return '?';
    }
  }

  /// Render structured data compactly: `{a: 1, b: foo}` becomes
  /// `a=1 b=foo`. Keeps lines greppable and short.
  static String _fmtData(Object data) {
    if (data is Map) {
      final buf = StringBuffer();
      var first = true;
      data.forEach((k, v) {
        if (!first) buf.write(' ');
        first = false;
        buf
          ..write(k)
          ..write('=')
          ..write(_fmtValue(v));
      });
      return buf.toString();
    }
    return data.toString();
  }

  static String _fmtValue(Object? v) {
    if (v == null) return 'null';
    if (v is num || v is bool) return v.toString();
    final s = v.toString();
    // Quote if it contains spaces or '=' so key=value parsing stays clean.
    if (s.contains(' ') || s.contains('=')) return '"$s"';
    return s;
  }

  static int _devLevel(Level lvl) {
    switch (lvl) {
      case Level.debug:
        return 500;
      case Level.info:
        return 800;
      case Level.warning:
        return 900;
      case Level.error:
        return 1000;
      default:
        return 800;
    }
  }
}
