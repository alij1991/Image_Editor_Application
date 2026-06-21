import 'dart:ui' show PlatformDispatcher, ErrorCallback;

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:image_editor/core/logging/app_logger.dart';
import 'package:image_editor/core/logging/error_handlers.dart';

/// XVI.116 (D1) — coverage for installErrorHandlers. Asserts both
/// process-global hooks are wired and forward to the logger, and that
/// the PlatformDispatcher hook reports the error as handled.
class _SpyLogger extends AppLogger {
  _SpyLogger() : super('Spy');
  final calls = <({String message, Object? error})>[];
  @override
  void e(String message, {Object? error, StackTrace? stackTrace, Object? data}) {
    calls.add((message: message, error: error));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // Save + restore the process-global handlers so these tests don't
  // leak into the rest of the suite (flutter_test installs its own).
  FlutterExceptionHandler? origFlutter;
  ErrorCallback? origPlatform;
  setUp(() {
    origFlutter = FlutterError.onError;
    origPlatform = PlatformDispatcher.instance.onError;
  });
  tearDown(() {
    FlutterError.onError = origFlutter;
    PlatformDispatcher.instance.onError = origPlatform;
  });

  test('installs both FlutterError + PlatformDispatcher handlers', () {
    installErrorHandlers(_SpyLogger());
    expect(FlutterError.onError, isNotNull);
    expect(PlatformDispatcher.instance.onError, isNotNull);
  });

  test('PlatformDispatcher handler forwards to logger and returns true',
      () {
    final spy = _SpyLogger();
    installErrorHandlers(spy);
    final err = StateError('async boom');
    final handled =
        PlatformDispatcher.instance.onError!(err, StackTrace.current);
    expect(handled, isTrue, reason: 'must mark the error handled');
    expect(spy.calls, hasLength(1));
    expect(spy.calls.single.message, contains('PlatformDispatcher'));
    expect(spy.calls.single.error, same(err));
  });

  test('FlutterError handler forwards the exception to the logger', () {
    final spy = _SpyLogger();
    installErrorHandlers(spy);
    final ex = StateError('widget boom');
    // presentError dumps to console (debug) — harmless; we only assert
    // the forward to the logger.
    FlutterError.onError!(FlutterErrorDetails(exception: ex));
    expect(spy.calls, hasLength(1));
    expect(spy.calls.single.message, contains('FlutterError'));
    expect(spy.calls.single.error, same(ex));
  });
}
