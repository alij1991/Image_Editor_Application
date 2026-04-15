import 'package:cunning_document_scanner/cunning_document_scanner.dart';
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
class NativeDocumentDetector implements DocumentDetector {
  const NativeDocumentDetector();

  @override
  DetectorStrategy get strategy => DetectorStrategy.native;

  @override
  Future<DetectionResult> capture({int maxPages = 10}) async {
    _log.i('launch', {'maxPages': maxPages});
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
    } catch (e, st) {
      _log.w('native unavailable', {'err': e.toString()});
      _log.d('stack', st);
      throw ScannerUnavailableException(e.toString());
    }
  }
}
