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

    test('metadataOnly entries are excluded from descriptors', () {
      // selfie_segmenter and face_detection_short are ML Kit models that
      // the SDK bundles itself — they must never appear in descriptors or
      // the Model Manager UI.
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
      "metadataOnly": true,
      "assetPath": "assets/models/bundled/selfie_segmenter.tflite"
    },
    {
      "id": "face_detection_short",
      "version": "1.0",
      "runtime": "mlkit",
      "sizeBytes": 204800,
      "sha256": "PLACEHOLDER",
      "bundled": true,
      "metadataOnly": true,
      "assetPath": "assets/models/bundled/face_detection_short.tflite"
    },
    {
      "id": "lama_inpaint",
      "version": "1.0",
      "runtime": "onnx",
      "sizeBytes": 218103808,
      "sha256": "abc",
      "bundled": false,
      "url": "https://example.com/lama.onnx"
    }
  ]
}
''';
      final manifest = ModelManifest.parse(json);
      // Only lama_inpaint should survive — both metadataOnly entries must
      // be filtered out before reaching the descriptor list.
      expect(manifest.descriptors.length, 1,
          reason: 'metadataOnly entries must not appear in descriptors');
      expect(manifest.byId('selfie_segmenter'), isNull,
          reason: 'selfie_segmenter is metadataOnly');
      expect(manifest.byId('face_detection_short'), isNull,
          reason: 'face_detection_short is metadataOnly');
      expect(manifest.byId('lama_inpaint'), isNotNull,
          reason: 'non-metadataOnly entry must still be present');
    });

    test('metadataOnly flag absent is treated as false', () {
      // Entries without the flag (the majority) should still parse normally.
      const json = '''
{"version": 1, "models": [
  {"id": "x", "version": "1", "runtime": "litert", "sizeBytes": 1,
   "sha256": "", "bundled": true, "assetPath": "x.tflite"}
]}''';
      final manifest = ModelManifest.parse(json);
      expect(manifest.descriptors.length, 1);
    });
  });
}
