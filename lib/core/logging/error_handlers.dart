import 'package:flutter/foundation.dart';

import 'app_logger.dart';

/// XVI.116 (D1) — install the process-wide error handlers that route
/// BOTH Flutter-framework errors and async / platform-engine errors to
/// [log].
///
/// Before this, only [FlutterError.onError] was set (in `bootstrap`),
/// so errors thrown off the widget build/layout/paint path —
/// uncaught Futures, errors inside `runZonedGuarded`-able callbacks,
/// platform-message handlers — were invisible: silent in release, a
/// console/red-screen only in debug. Google Play also gates store
/// visibility on the crash rate, so blind crashes are a release risk.
///
/// Two complementary hooks (belt-and-suspenders, the modern Flutter
/// recommendation):
///   - [FlutterError.onError]  — synchronous framework errors.
///   - [PlatformDispatcher.instance.onError] — async + platform/engine
///     errors that escape the framework.
/// The third surface (errors in zone-scheduled microtasks/timers) is
/// covered by the `runZonedGuarded` wrapper in `main()`.
///
/// MUST be called INSIDE the `runZonedGuarded` zone in `main()`, after
/// `WidgetsFlutterBinding.ensureInitialized()` and before the first
/// `await`, so the binding and `runApp` share one zone (otherwise
/// Flutter throws the "Zone mismatch" assertion at startup).
///
/// Today this is LOG-ONLY. The crash-reporter forward (D2 — Sentry or
/// equivalent) slots in at the two `log.e(...)` sites here.
void installErrorHandlers(AppLogger log) {
  // Synchronous Flutter-framework errors (build / layout / paint).
  FlutterError.onError = (FlutterErrorDetails details) {
    // Keep the default presenter (debug red-screen / console dump;
    // a no-op-ish console line in release) so behaviour matches the
    // pre-XVI.116 bootstrap handler.
    FlutterError.presentError(details);
    log.e(
      'FlutterError caught',
      error: details.exception,
      stackTrace: details.stack,
    );
  };

  // Async + platform/engine errors that escape the Flutter framework.
  // Returning true marks the error handled so the engine doesn't
  // re-report or abort.
  PlatformDispatcher.instance.onError = (Object error, StackTrace stack) {
    log.e(
      'PlatformDispatcher error caught',
      error: error,
      stackTrace: stack,
    );
    return true;
  };
}
