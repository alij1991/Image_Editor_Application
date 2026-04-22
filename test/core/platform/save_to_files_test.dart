import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:image_editor/core/platform/save_to_files.dart';

/// VIII.17 — `SaveToFiles.save` dispatches to the iOS method channel.
/// Non-iOS platforms short-circuit to `unsupported`; missing-plugin
/// (typical in unit tests) also reports `unsupported` so callers
/// don't surface a misleading error.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  void mockChannel(Future<Object?>? Function(MethodCall call)? handler) {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SaveToFiles.debugChannel, handler);
  }

  tearDown(() {
    mockChannel(null);
    debugDefaultTargetPlatformOverride = null;
  });

  test('isAvailable is true only on iOS', () {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    expect(SaveToFiles.isAvailable, isTrue);
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    expect(SaveToFiles.isAvailable, isFalse);
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    expect(SaveToFiles.isAvailable, isFalse);
  });

  test('save returns unsupported on non-iOS regardless of plugin state',
      () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    final result = await SaveToFiles.save('/tmp/anything.pdf');
    expect(result, SaveToFilesResult.unsupported);
  });

  test('save returns unsupported when the iOS plugin is missing',
      () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    // No mock registered — channel call throws MissingPluginException.
    final result = await SaveToFiles.save('/tmp/x.pdf');
    expect(result, SaveToFilesResult.unsupported);
  });

  test('save returns success when the plugin acks true', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    mockChannel((call) async {
      expect(call.method, 'save');
      expect(call.arguments, {'path': '/tmp/test.pdf'});
      return true;
    });
    final result = await SaveToFiles.save('/tmp/test.pdf');
    expect(result, SaveToFilesResult.success);
  });

  test('save returns cancelled when the plugin acks false', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    mockChannel((call) async => false);
    final result = await SaveToFiles.save('/tmp/test.pdf');
    expect(result, SaveToFilesResult.cancelled);
  });

  test('save returns error on PlatformException', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    mockChannel((call) async {
      throw PlatformException(code: 'BAD_ARGS', message: 'no path');
    });
    final result = await SaveToFiles.save('/tmp/test.pdf');
    expect(result, SaveToFilesResult.error);
  });
}
