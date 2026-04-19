import 'package:flutter_test/flutter_test.dart';

import 'package:image_editor/features/scanner/domain/document_classifier.dart';
import 'package:image_editor/features/scanner/domain/models/scan_models.dart';

ImageStats _stats({
  required int width,
  required int height,
  double colorRichness = 0.1,
}) =>
    ImageStats(width: width, height: height, colorRichness: colorRichness);

OcrResult _ocr(String text, {List<OcrBlock>? blocks}) => OcrResult(
      fullText: text,
      blocks: blocks ?? [],
    );

OcrBlock _block({
  required double left,
  required double top,
  required double width,
  required double height,
  String text = 'block',
}) =>
    OcrBlock(text: text, left: left, top: top, width: width, height: height);

void main() {
  const classifier = DocumentClassifier();

  group('DocumentClassifier', () {
    test('tall narrow page with money markers reads as receipt', () {
      final type = classifier.classify(
        stats: _stats(width: 600, height: 1400),
        ocr: _ocr('Subtotal 12.34\nTotal \$13.99\nThank you'),
      );
      expect(type, DocumentType.receipt);
      expect(type.suggestedFilter, ScanFilter.bw);
    });

    test('letter-aspect page with text density reads as document', () {
      // Aspect ~ 0.77 (US letter). 8000 / (1000*1300) = ~0.6%? Need
      // density above 2%. Use a single block covering 5% of the page.
      final type = classifier.classify(
        stats: _stats(width: 1000, height: 1300),
        ocr: _ocr('Dear customer, your invoice...', blocks: [
          _block(left: 50, top: 50, width: 800, height: 100),
        ]),
      );
      expect(type, DocumentType.invoiceOrLetter);
      expect(type.suggestedFilter, ScanFilter.magicColor);
    });

    test('wide landscape page with moderate colour reads as ID card', () {
      final type = classifier.classify(
        stats: _stats(width: 1600, height: 1000, colorRichness: 0.35),
        ocr: null,
      );
      expect(type, DocumentType.idCard);
      expect(type.suggestedFilter, ScanFilter.color);
    });

    test('saturated, text-less image reads as photo', () {
      final type = classifier.classify(
        stats: _stats(width: 1200, height: 800, colorRichness: 0.6),
        ocr: _ocr(''),
      );
      expect(type, DocumentType.photo);
      expect(type.suggestedFilter, ScanFilter.color);
    });

    test('square, low-text page reads as unknown (no rule fires)', () {
      final type = classifier.classify(
        stats: _stats(width: 1000, height: 1000, colorRichness: 0.05),
        ocr: _ocr(''),
      );
      expect(type, DocumentType.unknown);
      // Unknown defaults to the user's chosen filter — Auto.
      expect(type.suggestedFilter, ScanFilter.auto);
    });

    test('every DocumentType has a non-null label and suggested filter',
        () {
      for (final t in DocumentType.values) {
        expect(t.label.isNotEmpty, isTrue);
        expect(ScanFilter.values, contains(t.suggestedFilter));
      }
    });
  });
}
