import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:image_editor/ai/lab/corpus/corpus.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('TestCorpus.fromJsonString', () {
    test('parses a valid manifest', () {
      const json = '''
{
  "version": 1,
  "generatedBy": "scripts/generate_test_corpus.py",
  "seed": 42,
  "notes": "synthetic",
  "images": [
    {
      "id": "portrait_silhouette",
      "path": "assets/test_images/portrait_silhouette.png",
      "width": 1024,
      "height": 1536,
      "category": "portrait",
      "groundTruth": {
        "alpha": "assets/test_images/portrait_silhouette.alpha.png"
      },
      "expectedOps": ["bg_removal", "face_restore"],
      "notes": "hi"
    }
  ]
}
''';
      final corpus = TestCorpus.fromJsonString(json);
      expect(corpus.version, 1);
      expect(corpus.images, hasLength(1));
      final img = corpus.images.first;
      expect(img.id, 'portrait_silhouette');
      expect(img.width, 1024);
      expect(img.height, 1536);
      expect(img.expectedOps, ['bg_removal', 'face_restore']);
      expect(img.alphaPath, 'assets/test_images/portrait_silhouette.alpha.png');
      expect(img.notes, 'hi');
    });

    test('rejects unsupported version', () {
      const json = '''{"version": 99, "images": []}''';
      expect(
        () => TestCorpus.fromJsonString(json),
        throwsA(isA<FormatException>()),
      );
    });

    test('rejects non-list images', () {
      const json = '''{"version": 1, "images": "oops"}''';
      expect(
        () => TestCorpus.fromJsonString(json),
        throwsA(isA<FormatException>()),
      );
    });

    test('rejects non-int version', () {
      const json = '''{"version": "1", "images": []}''';
      expect(
        () => TestCorpus.fromJsonString(json),
        throwsA(isA<FormatException>()),
      );
    });

    test('parses tap_points ground truth', () {
      const json = '''
{
  "version": 1,
  "images": [
    {
      "id": "multi_subject",
      "path": "assets/test_images/multi_subject.png",
      "width": 1024,
      "height": 1024,
      "category": "multi_subject",
      "groundTruth": {
        "tap_points": [
          {"label": "circle", "x": 250, "y": 250},
          {"label": "square", "x": 774, "y": 250}
        ]
      },
      "expectedOps": ["mobile_sam_tap"]
    }
  ]
}
''';
      final corpus = TestCorpus.fromJsonString(json);
      final img = corpus.images.first;
      final taps = img.tapPoints;
      expect(taps, hasLength(2));
      expect(taps![0]['label'], 'circle');
      expect(taps[0]['x'], 250);
    });
  });

  group('TestCorpus queries', () {
    final corpus = TestCorpus.fromJsonString('''
{
  "version": 1,
  "images": [
    {
      "id": "a",
      "path": "x.png",
      "width": 1, "height": 1,
      "category": "cat",
      "groundTruth": {},
      "expectedOps": ["op1"]
    },
    {
      "id": "b",
      "path": "y.png",
      "width": 1, "height": 1,
      "category": "cat",
      "groundTruth": {},
      "expectedOps": ["op1", "op2"]
    }
  ]
}
''');

    test('byId returns the matching image', () {
      expect(corpus.byId('a').path, 'x.png');
      expect(corpus.byId('b').path, 'y.png');
    });

    test('byId throws when missing', () {
      expect(() => corpus.byId('zzz'), throwsStateError);
    });

    test('imagesFor filters by expectedOps', () {
      expect(corpus.imagesFor('op1').map((e) => e.id), ['a', 'b']);
      expect(corpus.imagesFor('op2').map((e) => e.id), ['b']);
      expect(corpus.imagesFor('op_none'), isEmpty);
    });
  });

  group('TestCorpus.load (real bundled manifest)', () {
    test('loads the real corpus manifest from rootBundle', () async {
      final corpus = await TestCorpus.load();
      expect(corpus.version, TestCorpus.kSupportedManifestVersion);
      expect(corpus.images, isNotEmpty);
      // Smoke-check a known image is present + has the expected
      // structure.
      final portrait = corpus.byId('portrait_silhouette');
      expect(portrait.width, 1024);
      expect(portrait.height, 1536);
      expect(portrait.alphaPath, isNotNull);
      expect(portrait.expectedOps, contains('bg_removal'));
    });

    test('all ground-truth asset paths in the real manifest exist',
        () async {
      final corpus = await TestCorpus.load();
      for (final img in corpus.images) {
        // Source image is bundleable.
        await expectLater(
          rootBundle.load(img.path),
          completes,
          reason: 'source missing: ${img.id} → ${img.path}',
        );
        // Each declared ground-truth path bundles too (except scalar
        // values like tap_points which are inline data).
        for (final entry in img.groundTruth.entries) {
          final value = entry.value;
          if (value is String) {
            await expectLater(
              rootBundle.load(value),
              completes,
              reason: 'ground truth missing: ${img.id} → '
                  '${entry.key} → $value',
            );
          }
        }
      }
    });

    test('manifest declares the expected ten images', () async {
      final corpus = await TestCorpus.load();
      final ids = corpus.images.map((e) => e.id).toSet();
      expect(
        ids,
        containsAll(<String>{
          'portrait_silhouette',
          'portrait_complex_hair',
          'landscape_clear_sky',
          'landscape_horizon_objects',
          'clean_grid',
          'noisy_grid',
          'sharp_grid',
          'blurred_grid',
          'multi_subject',
          'object_on_clutter',
        }),
      );
    });
  });
}
