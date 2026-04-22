import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';

import '../../../core/logging/app_logger.dart';
import '../domain/models/scan_models.dart';
import '../domain/ocr_engine.dart';

final _log = AppLogger('Ocr');

/// VIII.13 — Script the OCR recognizer should target. ML Kit ships a
/// separate model per script; switching scripts re-creates the
/// recognizer (one-time cost ~50-100 ms on first use).
///
/// Defaults to [latin] which matches the pre-VIII.13 hard-coded
/// behaviour. UI exposes a picker on the export page so users with
/// non-Latin documents (Chinese receipts, Devanagari forms) can
/// select the right script without leaving the scanner.
enum OcrScript {
  latin,
  chinese,
  japanese,
  korean,
  devanagari,
}

extension OcrScriptX on OcrScript {
  String get label {
    switch (this) {
      case OcrScript.latin:
        return 'Latin';
      case OcrScript.chinese:
        return 'Chinese';
      case OcrScript.japanese:
        return 'Japanese';
      case OcrScript.korean:
        return 'Korean';
      case OcrScript.devanagari:
        return 'Devanagari';
    }
  }

  /// Map our typed enum to ML Kit's plugin enum. Kept as an extension
  /// so the typed surface doesn't leak the plugin into the rest of
  /// the codebase.
  TextRecognitionScript get mlKit {
    switch (this) {
      case OcrScript.latin:
        return TextRecognitionScript.latin;
      case OcrScript.chinese:
        return TextRecognitionScript.chinese;
      case OcrScript.japanese:
        return TextRecognitionScript.japanese;
      case OcrScript.korean:
        return TextRecognitionScript.korean;
      case OcrScript.devanagari:
        return TextRecognitionScript.devanagiri;
    }
  }
}

/// On-device OCR pass over a processed scan page, producing an
/// [OcrResult] with block-level bounding boxes that the PDF and DOCX
/// exporters can overlay as invisible / visible text.
///
/// Implements [OcrEngine] so a future Apple-Vision-on-iOS engine can
/// be wired in without touching the notifier or exporters.
///
/// VIII.13 added per-call script selection — use [recognize]'s
/// `script` parameter (defaulting to [OcrScript.latin]) to swap
/// recognizers. The service caches one recognizer per script across
/// calls so repeated same-script work doesn't pay the load cost.
class OcrService implements OcrEngine {
  OcrService();

  final Map<OcrScript, TextRecognizer> _recognizers = {};

  TextRecognizer _ensure(OcrScript script) {
    return _recognizers[script] ??=
        TextRecognizer(script: script.mlKit);
  }

  @override
  Future<OcrResult> recognize(
    String imagePath, {
    OcrScript script = OcrScript.latin,
  }) async {
    final sw = Stopwatch()..start();
    final recognizer = _ensure(script);
    try {
      final input = InputImage.fromFilePath(imagePath);
      final result = await recognizer.processImage(input);
      final blocks = <OcrBlock>[
        for (final b in result.blocks)
          OcrBlock(
            text: b.text,
            left: b.boundingBox.left,
            top: b.boundingBox.top,
            width: b.boundingBox.width,
            height: b.boundingBox.height,
          ),
      ];
      _log.d('ok', {
        'path': imagePath,
        'script': script.name,
        'blocks': blocks.length,
        'chars': result.text.length,
        'ms': sw.elapsedMilliseconds,
      });
      return OcrResult(fullText: result.text, blocks: blocks);
    } catch (e, st) {
      _log.w('failed', {'err': e.toString(), 'script': script.name});
      _log.d('stack', st);
      return const OcrResult(fullText: '', blocks: []);
    }
  }

  @override
  Future<void> dispose() async {
    for (final r in _recognizers.values) {
      await r.close();
    }
    _recognizers.clear();
  }
}
