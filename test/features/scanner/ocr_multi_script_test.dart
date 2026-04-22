import 'package:flutter_test/flutter_test.dart';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';

import 'package:image_editor/features/scanner/data/ocr_service.dart';
import 'package:image_editor/features/scanner/domain/models/scan_models.dart';

/// VIII.13 — multi-script OCR. `OcrService.recognize(script: ...)`
/// targets ML Kit's per-script recognizers; `ExportOptions` carries
/// the chosen script through to the export pipeline.
void main() {
  group('OcrScript enum', () {
    test('has all five ML Kit scripts', () {
      expect(OcrScript.values, [
        OcrScript.latin,
        OcrScript.chinese,
        OcrScript.japanese,
        OcrScript.korean,
        OcrScript.devanagari,
      ]);
    });

    test('label is human-readable', () {
      expect(OcrScript.latin.label, 'Latin');
      expect(OcrScript.chinese.label, 'Chinese');
      expect(OcrScript.japanese.label, 'Japanese');
      expect(OcrScript.korean.label, 'Korean');
      expect(OcrScript.devanagari.label, 'Devanagari');
    });

    test('mlKit mapping returns the correct ML Kit enum', () {
      expect(OcrScript.latin.mlKit, TextRecognitionScript.latin);
      expect(OcrScript.chinese.mlKit, TextRecognitionScript.chinese);
      expect(OcrScript.japanese.mlKit, TextRecognitionScript.japanese);
      expect(OcrScript.korean.mlKit, TextRecognitionScript.korean);
      expect(OcrScript.devanagari.mlKit, TextRecognitionScript.devanagiri);
    });
  });

  group('ExportOptions.ocrScript', () {
    test('defaults to Latin', () {
      expect(const ExportOptions().ocrScript, OcrScript.latin);
    });

    test('copyWith updates ocrScript independently', () {
      const opts = ExportOptions();
      final next = opts.copyWith(ocrScript: OcrScript.chinese);
      expect(next.ocrScript, OcrScript.chinese);
      expect(next.format, ExportFormat.pdf);
      expect(next.includeOcr, isTrue);
    });

    test('copyWith preserves ocrScript when other fields change', () {
      const opts = ExportOptions(ocrScript: OcrScript.japanese);
      final next = opts.copyWith(format: ExportFormat.docx);
      expect(next.ocrScript, OcrScript.japanese);
      expect(next.format, ExportFormat.docx);
    });
  });
}
