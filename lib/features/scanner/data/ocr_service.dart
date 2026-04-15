import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';

import '../../../core/logging/app_logger.dart';
import '../domain/models/scan_models.dart';

final _log = AppLogger('Ocr');

/// On-device OCR pass over a processed scan page, producing an
/// [OcrResult] with block-level bounding boxes that the PDF and DOCX
/// exporters can overlay as invisible / visible text.
///
/// Uses Google ML Kit's text recognizer which runs on both Android and
/// iOS without a network call. Latin script only for Phase B — other
/// scripts can be added later by swapping the recognizer.
class OcrService {
  OcrService();

  TextRecognizer? _recognizer;

  TextRecognizer _ensure() {
    return _recognizer ??= TextRecognizer(script: TextRecognitionScript.latin);
  }

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

  Future<void> dispose() async {
    await _recognizer?.close();
    _recognizer = null;
  }
}
