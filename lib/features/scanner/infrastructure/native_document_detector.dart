import 'package:cunning_document_scanner/cunning_document_scanner.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:uuid/uuid.dart';

import '../../../core/logging/app_logger.dart';
import '../domain/document_detector.dart';
import '../domain/models/scan_models.dart';

final _log = AppLogger('NativeDetector');

/// Full-screen native scanner backed by `cunning_document_scanner`.
///
/// On Android this uses Google ML Kit's document scanner activity; on
/// iOS it uses Apple's VisionKit. Both already handle edge detection,
/// perspective warp, multi-page capture and filters internally, so we
/// store the returned images with `Corners.full()` and skip the
/// in-app warp.
///
/// Requests the camera permission ourselves before invoking the
/// native UI — otherwise `cunning_document_scanner` throws a generic
/// "Permission not granted" exception that gets surfaced as a vague
/// "Native scanner unavailable" message. With an explicit pre-check
/// we can route the user to Settings on permanent denial and skip
/// the dialog on already-granted.
class NativeDocumentDetector implements DocumentDetector {
  const NativeDocumentDetector();

  @override
  DetectorStrategy get strategy => DetectorStrategy.native;

  @override
  Future<DetectionResult> capture({int maxPages = 10}) async {
    _log.i('launch', {'maxPages': maxPages});
    final permissionStatus = await _ensureCameraPermission();
    if (permissionStatus != PermissionStatus.granted) {
      _log.w('permission denied', {'status': permissionStatus.name});
      throw NativeScannerPermissionException(permissionStatus);
    }
    try {
      final paths = await CunningDocumentScanner.getPictures(
        noOfPages: maxPages,
        isGalleryImportAllowed: true,
      );
      if (paths == null || paths.isEmpty) {
        _log.d('cancelled');
        throw const ScannerCancelledException();
      }
      _log.i('captured', {'count': paths.length});
      const uuid = Uuid();
      final pages = [
        for (final path in paths)
          ScanPage(
            id: uuid.v4(),
            rawImagePath: path,
            processedImagePath: path, // already warped+filtered by native UI
            corners: Corners.full(),
          ),
      ];
      return DetectionResult(
        pages: pages,
        strategyUsed: DetectorStrategy.native,
      );
    } on ScannerCancelledException {
      rethrow;
    } on NativeScannerPermissionException {
      rethrow;
    } catch (e, st) {
      _log.w('native unavailable', {'err': e.toString()});
      _log.d('stack', st);
      throw ScannerUnavailableException(e.toString());
    }
  }

  /// Resolve the current camera permission state. Always calls
  /// [Permission.camera.request] — iOS / Android both short-circuit
  /// on already-granted (no dialog), so there's no UX cost, and the
  /// live call avoids a permission_handler bug where `.status` kept
  /// returning a stale `permanentlyDenied` after the user enabled
  /// Camera in Settings without restarting the app. Field-log
  /// reproduction: user toggled Camera on in Settings, returned to
  /// the app, tapped Scan, still saw "Camera access is blocked"
  /// because the cached `.status` hadn't refreshed.
  Future<PermissionStatus> _ensureCameraPermission() {
    return Permission.camera.request();
  }
}

/// Thrown by [NativeDocumentDetector.capture] when the camera
/// permission gate failed. [status] tells the UI whether to show
/// "tap allow" coaching or an "Open Settings" call-to-action.
class NativeScannerPermissionException implements Exception {
  const NativeScannerPermissionException(this.status);
  final PermissionStatus status;

  /// True when the OS won't show the permission dialog again — the
  /// only path forward is the system Settings app.
  bool get requiresSettings =>
      status.isPermanentlyDenied || status.isRestricted;

  /// User-facing message paired with the exception. Kept here so the
  /// review/capture pages don't have to rebuild the wording.
  String get message => requiresSettings
      ? 'Camera access is blocked in Settings. Open Settings to enable '
          'it for this app.'
      : 'Camera permission is needed to scan documents with the '
          'native scanner.';

  @override
  String toString() =>
      'NativeScannerPermissionException(${status.name}: $message)';
}
