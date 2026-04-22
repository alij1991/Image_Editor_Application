import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

import 'package:image_editor/features/scanner/data/image_stats_extractor.dart';
import 'package:image_editor/features/scanner/domain/document_classifier.dart';

/// VIII.11 — `DocumentClassifier` demotes blurry, colour-rich frames
/// from `photo` to `unknown`. Pre-VIII.11 a blurry document scan with
/// any colour saturation would mis-tag as `photo` and route the user
/// to the wrong default filter.
void main() {
  group('computeSharpness', () {
    test('uniform image produces ~0 sharpness', () {
      final flat = img.Image(width: 64, height: 64);
      img.fill(flat, color: img.ColorRgb8(128, 128, 128));
      expect(computeSharpness(flat), lessThan(0.05));
    });

    test('checkerboard image produces high sharpness', () {
      final checker = img.Image(width: 64, height: 64);
      for (var y = 0; y < 64; y++) {
        for (var x = 0; x < 64; x++) {
          final on = ((x + y) ~/ 2) % 2 == 0;
          checker.setPixel(
            x,
            y,
            img.ColorRgb8(
              on ? 255 : 0,
              on ? 255 : 0,
              on ? 255 : 0,
            ),
          );
        }
      }
      expect(computeSharpness(checker), greaterThan(0.5));
    });

    test('sharpness is bounded in [0..1]', () {
      final flat = img.Image(width: 32, height: 32);
      img.fill(flat, color: img.ColorRgb8(50, 50, 50));
      final s = computeSharpness(flat);
      expect(s, inInclusiveRange(0.0, 1.0));
    });

    test('< 3px image returns 1.0 (no Laplacian possible)', () {
      final tiny = img.Image(width: 2, height: 2);
      expect(computeSharpness(tiny), 1.0);
    });
  });

  group('DocumentClassifier blur awareness', () {
    const classifier = DocumentClassifier();

    test('sharp + colour-rich + low text → photo (legacy behaviour)', () {
      final type = classifier.classify(
        stats: const ImageStats(
          width: 1000,
          height: 1000,
          colorRichness: 0.7,
          sharpness: 0.85,
        ),
      );
      expect(type, DocumentType.photo);
    });

    test('blurry + colour-rich + low text → unknown (VIII.11 demotion)',
        () {
      final type = classifier.classify(
        stats: const ImageStats(
          width: 1000,
          height: 1000,
          colorRichness: 0.7,
          sharpness: 0.10, // Below kBlurredSharpnessThreshold (0.30).
        ),
      );
      expect(type, DocumentType.unknown);
    });

    test('borderline-sharp colour-rich frame stays in photo bucket', () {
      // sharpness == kBlurredSharpnessThreshold — the strict `<`
      // means this is NOT considered blurry.
      final type = classifier.classify(
        stats: ImageStats(
          width: 1000,
          height: 1000,
          colorRichness: 0.7,
          sharpness: kBlurredSharpnessThreshold,
        ),
      );
      expect(type, DocumentType.photo);
    });

    test('default sharpness 1.0 keeps pre-VIII.11 behaviour for callers '
        'that omit it', () {
      final type = classifier.classify(
        stats: const ImageStats(
          width: 1000,
          height: 1000,
          colorRichness: 0.7,
        ),
      );
      expect(type, DocumentType.photo);
    });
  });
}
