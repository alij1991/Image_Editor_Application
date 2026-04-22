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
  final CornerSeeder seeder;
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
    final selected = paths.take(maxPages).toList();
    var fellBackCount = 0;

    // Phase V.9: route auto-seeding through [seedBatch] so the
    // OpenCV implementation can run the whole multi-page import
    // inside ONE worker isolate (previously one isolate-equivalent
    // main-thread trip per page). Manual mode keeps the trivial
    // Corners.inset fan-out — no seeding work to batch.
    List<SeedResult>? seeded;
    if (useAutoSeed && selected.isNotEmpty) {
      seeded = await seeder.seedBatch(selected);
    }

    for (int i = 0; i < selected.length; i++) {
      Corners corners;
      if (useAutoSeed) {
        final result = seeded![i];
        corners = result.corners;
        if (result.fellBack) fellBackCount++;
      } else {
        corners = Corners.inset();
      }
      pages.add(ScanPage(
        id: uuid.v4(),
        rawImagePath: selected[i],
        corners: corners,
      ));
    }
    _log.i('picked', {'pages': pages.length, 'fellBack': fellBackCount});
    return DetectionResult(
      pages: pages,
      strategyUsed: strategy,
      autoFellBackCount: fellBackCount,
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
