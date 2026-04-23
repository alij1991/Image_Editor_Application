import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../ai/services/object_detection/object_detector_service.dart';
import '../../../core/logging/app_logger.dart';
import '../../../di/providers.dart' as app;
import '../data/docx_exporter.dart';
import '../data/image_processor.dart';
import '../data/jpeg_zip_exporter.dart';
import '../data/ocr_service.dart';
import '../data/pdf_exporter.dart';
import '../data/scan_repository.dart';
import '../data/text_exporter.dart';
import '../domain/models/scan_models.dart';
import '../infrastructure/capabilities_probe.dart';
import '../infrastructure/classical_corner_seed.dart';
import '../infrastructure/hough_quad_corner_seed.dart';
import '../infrastructure/image_picker_capture.dart';
import '../infrastructure/opencv_corner_seed.dart';
import '../infrastructure/scanner_region_prior.dart';
import 'scanner_notifier.dart';

final _providersLog = AppLogger('ScannerProviders');

/// Capability probe — safe to recreate; it's stateless.
final capabilitiesProbeProvider = Provider<CapabilitiesProbe>(
  (_) => const CapabilitiesProbe(),
);

/// Shared image processor used for warp+filter on every page.
final scanImageProcessorProvider = Provider<ScanImageProcessor>(
  (_) => ScanImageProcessor(),
);

/// Exporters — each is stateless and cheap to instantiate.
final pdfExporterProvider = Provider<PdfExporter>((_) => const PdfExporter());
final docxExporterProvider = Provider<DocxExporter>((_) => const DocxExporter());
final textExporterProvider = Provider<TextExporter>((_) => const TextExporter());
final jpegZipExporterProvider =
    Provider<JpegZipExporter>((_) => const JpegZipExporter());

/// OCR service holds a native TextRecognizer; close it on dispose.
final ocrServiceProvider = Provider<OcrService>((ref) {
  final svc = OcrService();
  ref.onDispose(svc.dispose);
  return svc;
});

/// Persistence for finished scan sessions.
final scanRepositoryProvider =
    Provider<ScanRepository>((_) => ScanRepository());

/// Lazily-loaded history list. Consumers use `ref.refresh` after
/// saving a new session.
final scanHistoryProvider = FutureProvider<List<ScanSession>>((ref) async {
  final repo = ref.watch(scanRepositoryProvider);
  return repo.loadAll();
});

/// Camera / gallery picker used by Manual and Auto strategies.
final imagePickerCaptureProvider =
    Provider<ImagePickerCapture>((_) => ImagePickerCapture());

/// Pure-Dart corner seeding heuristic — kept addressable so it can be
/// referenced as the fallback in the chained seeder below or injected
/// directly in unit tests where the OpenCV native lib isn't loaded.
final classicalCornerSeedProvider =
    Provider<ClassicalCornerSeed>((_) => const ClassicalCornerSeed());

/// Phase XIV.3: optional EfficientDet-Lite0 region prior for the
/// corner seeder. Lazily loaded — the first scanner session that
/// runs the Auto strategy pays the ~50 ms model-load cost; the
/// session keeps the detector warm for subsequent pages in the same
/// multi-page import.
///
/// Returns null silently on any failure (manifest missing the
/// entry, asset copy fails, interpreter build fails). The seeder
/// then runs without a prior, matching pre-XIV.3 behaviour.
final scannerRegionPriorProvider = FutureProvider<ScannerRegionPrior?>(
  (ref) async {
    try {
      final registry = ref.watch(app.modelRegistryProvider);
      final resolved = await registry.resolve('efficientdet_lite0');
      if (resolved == null) {
        _providersLog
            .d('efficientdet_lite0 not resolved — scanner runs without prior');
        return null;
      }
      final session = await ref.watch(app.liteRtRuntimeProvider).load(resolved);
      final detector =
          ObjectDetectorService.efficientDetLite0(session: session);
      final prior = ObjectDetectorRegionPrior(detector: detector);
      ref.onDispose(prior.close);
      return prior;
    } catch (e) {
      _providersLog.w('scanner region prior load failed — falling back',
          {'err': e.toString()});
      return null;
    }
  },
);

/// Active corner seeder for the Auto strategy.
///
/// Phase XVI.3 chain (primary → last-resort):
///   1. [HoughQuadCornerSeed] — probabilistic Hough + cluster + quad
///      intersection. Best on cluttered backgrounds where text and
///      table edges swamp the contour finder.
///   2. [OpenCvCornerSeed] — Canny + `findContours` + `approxPolyDP`.
///      Optional region prior from the object detector (XIV.3)
///      narrows the contour search to a document-shaped bbox.
///   3. [ClassicalCornerSeed] — Sobel gradient bounding-box. Runs
///      pure Dart, no native dep.
///   4. `Corners.inset()` — safety net.
///
/// The order matters: Hough is stricter (it demands straight-edge
/// evidence) so when it succeeds the result is usually tighter than
/// contour's. Contour then catches photos where one page edge is in
/// shadow and Hough lost the line.
final cornerSeederProvider = Provider<CornerSeeder>(
  (ref) => HoughQuadCornerSeed(
    fallback: OpenCvCornerSeed(
      fallback: ref.watch(classicalCornerSeedProvider),
      regionPrior: ref.watch(scannerRegionPriorProvider).valueOrNull,
    ),
  ),
);

/// The active scanner session. One at a time; cleared when the user
/// exits the flow.
final scannerNotifierProvider =
    StateNotifierProvider<ScannerNotifier, ScannerState>((ref) {
  return ScannerNotifier(
    probe: ref.watch(capabilitiesProbeProvider),
    processor: ref.watch(scanImageProcessorProvider),
    ocr: ref.watch(ocrServiceProvider),
    repository: ref.watch(scanRepositoryProvider),
    picker: ref.watch(imagePickerCaptureProvider),
    cornerSeed: ref.watch(cornerSeederProvider),
  );
});
