import '../../scanner/domain/models/scan_models.dart';

/// Detection result for a single capture call. Returns the path(s) of
/// the captured image on disk plus the strategy actually used.
class DetectionResult {
  const DetectionResult({
    required this.pages,
    required this.strategyUsed,
  });

  final List<ScanPage> pages;
  final DetectorStrategy strategyUsed;
}

/// Thrown by a detector when the user cancels the capture flow.
class ScannerCancelledException implements Exception {
  const ScannerCancelledException();
  @override
  String toString() => 'ScannerCancelledException';
}

/// Thrown when a detector cannot run on this device (e.g. Play Services
/// missing for the native strategy). The notifier catches this and
/// falls back to manual.
class ScannerUnavailableException implements Exception {
  const ScannerUnavailableException(this.reason);
  final String reason;
  @override
  String toString() => 'ScannerUnavailableException($reason)';
}

/// Strategy interface. Different detectors plug in without changing the
/// notifier/UI.
abstract class DocumentDetector {
  DetectorStrategy get strategy;

  /// Run the capture flow. Should throw [ScannerCancelledException] if
  /// the user dismisses without picking anything.
  Future<DetectionResult> capture({int maxPages = 10});
}
