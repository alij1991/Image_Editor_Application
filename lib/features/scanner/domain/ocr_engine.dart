import '../data/ocr_service.dart' show OcrScript;
import 'models/scan_models.dart';

/// Common surface every OCR engine implements. Lets the notifier swap
/// between Google ML Kit (current default — works on both platforms)
/// and Apple Vision (future iOS upgrade for higher accuracy on
/// printed and handwritten text) without changing call sites.
///
/// Implementations live under `data/` so this domain interface stays
/// dependency-free.
abstract class OcrEngine {
  /// Recognise text in the image at [imagePath] using [script] (default
  /// Latin). Implementations must not throw — return an empty
  /// [OcrResult] when recognition fails so the caller can stay agnostic
  /// to the underlying engine.
  Future<OcrResult> recognize(
    String imagePath, {
    OcrScript script = OcrScript.latin,
  });

  /// Release any platform resources (open recognizers, native models).
  /// Idempotent.
  Future<void> dispose();
}
