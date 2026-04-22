import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../logging/app_logger.dart';

final _log = AppLogger('SaveToFiles');

/// VIII.17 — iOS-only "Save to Files" quick action.
///
/// On iOS, the existing share sheet exposes "Save to Files" as one of
/// many actions, requiring two taps. This helper invokes the native
/// `UIDocumentPickerViewController(forExporting:)` directly via a
/// method channel so the user gets a one-tap save.
///
/// On non-iOS platforms (or when the method channel isn't registered
/// — e.g. in unit tests), [save] returns [SaveToFilesResult.unsupported]
/// without throwing so the caller can hide / disable the button
/// gracefully.
class SaveToFiles {
  const SaveToFiles._();

  static const MethodChannel _channel =
      MethodChannel('com.imageeditor/save_to_files');

  /// True only on iOS (where the native plugin can run).
  static bool get isAvailable => !kIsWeb && defaultTargetPlatform == TargetPlatform.iOS;

  /// Open the iOS Files picker pointed at [filePath]. Returns the
  /// outcome — `success`, `cancelled`, `unsupported`, or `error`.
  /// Uses a typed result struct (not throws) so the caller can react
  /// without a try/catch.
  static Future<SaveToFilesResult> save(String filePath) async {
    if (!isAvailable) {
      return SaveToFilesResult.unsupported;
    }
    try {
      final ok = await _channel.invokeMethod<bool>('save', {
        'path': filePath,
      });
      _log.i('save dispatch', {'path': filePath, 'ok': ok});
      if (ok == true) return SaveToFilesResult.success;
      if (ok == false) return SaveToFilesResult.cancelled;
      return SaveToFilesResult.error;
    } on MissingPluginException {
      // Plugin not registered (e.g. running on a debug build without
      // the iOS native side, or unit tests). Surface as unsupported
      // so callers don't show a misleading error.
      _log.d('plugin not registered');
      return SaveToFilesResult.unsupported;
    } on PlatformException catch (e) {
      _log.w('platform exception', {'code': e.code, 'msg': e.message});
      return SaveToFilesResult.error;
    }
  }

  /// Test seam — exposes the underlying [MethodChannel] so tests can
  /// register a mock handler via the
  /// `TestDefaultBinaryMessengerBinding` API. Lives here (instead of
  /// the test file using `MethodChannel('com.imageeditor/...')`
  /// directly) so the channel name stays in one place.
  @visibleForTesting
  static MethodChannel get debugChannel => _channel;
}

/// Outcome of [SaveToFiles.save].
enum SaveToFilesResult {
  /// User picked a destination + the file was saved.
  success,

  /// User dismissed the picker without choosing a destination.
  cancelled,

  /// Platform doesn't support the helper (non-iOS, or the native
  /// plugin isn't bundled). Caller should hide the entry point.
  unsupported,

  /// An unexpected error occurred. Logs are written via
  /// [AppLogger].
  error,
}
