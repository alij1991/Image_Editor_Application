import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';

import '../../../core/logging/app_logger.dart';
import '../domain/document_detector.dart';
import '../domain/models/scan_models.dart';
import 'classical_corner_seed.dart';
import 'image_picker_capture.dart';

final _log = AppLogger('ManualDetector');

/// "Manual" and "Auto" detectors in one class — both go through the
/// image-picker, the only difference is whether we seed corners from a
/// classical edge heuristic or from a safe default inset.
///
/// After capture, the user always lands on the crop page and can drag
/// the corners before the perspective warp is applied.
class ManualDocumentDetector implements DocumentDetector {
  ManualDocumentDetector({
    required this.picker,
    required this.seeder,
    required this.useAutoSeed,
    this.pickSource = ManualPickSource.askUser,
  });

  final ImagePickerCapture picker;
  final ClassicalCornerSeed seeder;
  final bool useAutoSeed;
  final ManualPickSource pickSource;

  @override
  DetectorStrategy get strategy =>
      useAutoSeed ? DetectorStrategy.auto : DetectorStrategy.manual;

  @override
  Future<DetectionResult> capture({int maxPages = 10}) async {
    _log.i('capture', {
      'auto': useAutoSeed,
      'source': pickSource.name,
      'maxPages': maxPages,
    });
    final paths = await _pickPaths();
    const uuid = Uuid();
    final pages = <ScanPage>[];
    for (final path in paths.take(maxPages)) {
      final corners = useAutoSeed ? await seeder.seed(path) : Corners.inset();
      pages.add(ScanPage(
        id: uuid.v4(),
        rawImagePath: path,
        corners: corners,
      ));
    }
    _log.i('picked', {'pages': pages.length});
    return DetectionResult(
      pages: pages,
      strategyUsed: strategy,
    );
  }

  Future<List<String>> _pickPaths() {
    switch (pickSource) {
      case ManualPickSource.camera:
        return picker.pickFromCamera();
      case ManualPickSource.gallery:
        return picker.pickFromGallery(multi: true);
      case ManualPickSource.askUser:
        // The capture page's entry point asks the user which source; if
        // we get here without a choice, prefer camera. Kept as a safe
        // default so the detector never silently does nothing.
        if (kDebugMode) _log.w('pickSource=askUser; defaulting to camera');
        return picker.pickFromCamera();
    }
  }
}

enum ManualPickSource { camera, gallery, askUser }
