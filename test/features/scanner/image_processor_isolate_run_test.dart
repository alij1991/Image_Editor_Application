import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// X.B.3 — `ScanImageProcessor` migrated from `compute()` to
/// `Isolate.run` with a restart path. Pre-X.B.3 a failed `compute()`
/// fell back to running `_processInIsolate` synchronously on the
/// main thread, freezing the UI for 3-7 s on 12 MP captures.
/// Post-X.B.3 the retry path keeps work off the main thread; on
/// total failure the processor returns an empty buffer (the same
/// graceful-degrade signal the decoder uses) so the caller leaves
/// the page on its placeholder.
///
/// The behavioural contract is covered by `undecodable_pick_test.dart`
/// (decode-failure → null processedImagePath). These tests pin the
/// *implementation* contract so a future refactor doesn't silently
/// reintroduce the main-thread freeze by pulling the fallback back:
///   1. `dart:isolate` is imported (signals Isolate.run usage).
///   2. `Isolate.run(` appears in the processing path.
///   3. `compute(` is NOT used for the page-processing path.
///   4. The degradation path returns `Uint8List(0)` rather than
///      calling the isolate body from the main thread.
void main() {
  late String source;

  setUpAll(() async {
    source =
        await File('lib/features/scanner/data/image_processor.dart').readAsString();
  });

  test('imports dart:isolate', () {
    expect(source, contains("import 'dart:isolate';"),
        reason: 'Isolate.run lives in dart:isolate');
  });

  test('uses Isolate.run for the page-processing path', () {
    expect(source, contains('Isolate.run('),
        reason: 'X.B.3 migrated the per-page render to Isolate.run so a '
            'retry is possible without reusing the crashed isolate');
  });

  test('does NOT use compute() for the page-processing path', () {
    // `compute` may still appear in doc comments referencing the
    // pre-X.B.3 implementation; the invariant is that no call-site
    // survives. Match the function call, not the bare word.
    expect(source, isNot(contains('await compute(')),
        reason: 'compute() shelled out to a throwaway isolate per call; '
            'Isolate.run replaces it');
  });

  test('degradation does not re-enter _processInIsolate on the main thread',
      () {
    // The pre-X.B.3 catch block called `_processInIsolate(payload)` on
    // the main thread — that line is gone. The new degradation path
    // returns `Uint8List(0)` so the caller degrades gracefully.
    expect(source, contains('return Uint8List(0);'),
        reason: 'degradation path returns empty bytes, not a main-thread '
            'call to the CPU-heavy body');
    // There's still one `_processInIsolate(payload)` inside the
    // `Isolate.run` closure; outside that closure the function must
    // not be invoked.
    final mainThreadInvocationPattern =
        RegExp(r'^\s*jpeg = _processInIsolate\(payload\);', multiLine: true);
    expect(mainThreadInvocationPattern.hasMatch(source), isFalse,
        reason: 'no main-thread body invocation should remain');
  });
}
