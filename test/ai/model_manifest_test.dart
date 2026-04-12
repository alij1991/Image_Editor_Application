import 'package:flutter_test/flutter_test.dart';

import 'package:image_editor/ai/models/model_descriptor.dart';
import 'package:image_editor/ai/models/model_manifest.dart';

void main() {
  group('ModelManifest.parse', () {
    test('parses the bundled manifest shape', () {
      const json = '''
{
  "version": 1,
  "models": [
    {
      "id": "selfie_segmenter",
      "version": "1.0",
      "runtime": "mlkit",
      "sizeBytes": 524288,
      "sha256": "PLACEHOLDER",
      "bundled": true,
      "assetPath": "assets/models/bundled/selfie_segmenter.tflite",
      "url": null,
      "purpose": "MediaPipe Selfie Segmentation"
    },
    {
      "id": "lama_inpaint",
      "version": "1.0",
      "runtime": "onnx",
      "sizeBytes": 218103808,
      "sha256": "PLACEHOLDER",
      "bundled": false,
      "assetPath": null,
      "url": "https://example.com/lama.onnx",
      "purpose": "LaMa object removal"
    }
  ]
}
''';
      final manifest = ModelManifest.parse(json);
      expect(manifest.descriptors.length, 2);
      expect(manifest.bundled.length, 1);
      expect(manifest.downloadable.length, 1);
    });

    test('byId returns the matching descriptor', () {
      const json = '''
{"version": 1, "models": [
  {"id": "a", "version": "1", "runtime": "mlkit", "sizeBytes": 1,
   "sha256": "", "bundled": true, "assetPath": "x"},
  {"id": "b", "version": "1", "runtime": "litert", "sizeBytes": 2,
   "sha256": "", "bundled": true, "assetPath": "y"}
]}
''';
      final manifest = ModelManifest.parse(json);
      expect(manifest.byId('a')?.assetPath, 'x');
      expect(manifest.byId('b')?.runtime, ModelRuntime.litert);
      expect(manifest.byId('missing'), isNull);
    });

    test('skips entries with missing runtime field', () {
      const json = '''
{"version": 1, "models": [
  {"id": "valid", "version": "1", "runtime": "mlkit", "sizeBytes": 1,
   "sha256": "", "bundled": true, "assetPath": "x"},
  {"id": "invalid", "version": "1", "sizeBytes": 1,
   "sha256": "", "bundled": true, "assetPath": "x"}
]}
''';
      final manifest = ModelManifest.parse(json);
      expect(manifest.descriptors.length, 1);
      expect(manifest.byId('valid'), isNotNull);
      expect(manifest.byId('invalid'), isNull);
    });

    test('empty models array yields empty manifest', () {
      const json = '{"version": 1, "models": []}';
      final manifest = ModelManifest.parse(json);
      expect(manifest.descriptors, isEmpty);
    });
  });
}
