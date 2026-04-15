import 'package:flutter_riverpod/flutter_riverpod.dart';

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
import '../infrastructure/image_picker_capture.dart';
import 'scanner_notifier.dart';

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

/// Pure-Dart corner seeding heuristic for the Auto strategy.
final classicalCornerSeedProvider =
    Provider<ClassicalCornerSeed>((_) => const ClassicalCornerSeed());

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
    cornerSeed: ref.watch(classicalCornerSeedProvider),
  );
});
