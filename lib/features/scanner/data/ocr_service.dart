import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';

import '../../../core/logging/app_logger.dart';
import '../domain/models/scan_models.dart';
import '../domain/ocr_engine.dart';

final _log = AppLogger('Ocr');

/// On-device OCR pass over a processed scan page, producing an
/// [OcrResult] with block-level bounding boxes that the PDF and DOCX
/// exporters can overlay as invisible / visible text.
///
/// Implements [OcrEngine] so a future Apple-Vision-on-iOS engine can
/// be wired in without touching the notifier or exporters. Latin
/// script only for Phase B — other scripts can be added later by
/// swapping the recognizer or routing per-locale.
class OcrService implements OcrEngine {
  OcrService();

  TextRecognizer? _recognizer;

  TextRecognizer _ensure() {
    return _recognizer ??= TextRecognizer(script: TextRecognitionScript.latin);
  }

  @override
  Future<OcrResult> recognize(String imagePath) async {
    final sw = Stopwatch()..start();
    final recognizer = _ensure();
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
        'blocks': blocks.length,
        'chars': result.text.length,
        'ms': sw.elapsedMilliseconds,
      });
      return OcrResult(fullText: result.text, blocks: blocks);
    } catch (e, st) {
      _log.w('failed', {'err': e.toString()});
      _log.d('stack', st);
      return const OcrResult(fullText: '', blocks: []);
    }
  }

  @override
  Future<void> dispose() async {
    await _recognizer?.close();
    _recognizer = null;
  }
}
