import '../../scanner/domain/models/scan_models.dart';

/// Detection result for a single capture call. Returns the path(s) of
/// the captured image on disk plus the strategy actually used.
///
/// [autoFellBackCount] is the number of pages where the Auto detector
/// couldn't find usable edges and seeded an inset rectangle instead;
/// the UI uses this to coach the user to drag corners themselves.
///
/// [autoFellBackPages] is the 1-based list of page numbers the user
/// would see in the strip — populated when [autoFellBackCount] > 0 so
/// the coaching banner can name specific pages (VIII.14). Empty when
/// every page was detected successfully.
class DetectionResult {
  const DetectionResult({
    required this.pages,
    required this.strategyUsed,
    this.autoFellBackCount = 0,
    this.autoFellBackPages = const [],
  });

  final List<ScanPage> pages;
  final DetectorStrategy strategyUsed;
  final int autoFellBackCount;
  final List<int> autoFellBackPages;
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
