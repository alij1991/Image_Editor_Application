import 'package:flutter_test/flutter_test.dart';

import 'package:image_editor/ai/models/model_descriptor.dart';

void main() {
  group('ModelDescriptor', () {
    test('bundled TFLite descriptor parses from manifest JSON', () {
      const jsonStr = {
        'id': 'selfie_segmenter',
        'version': '1.0',
        'runtime': 'mlkit',
        'size_bytes': 524288,
        'sha256': 'PLACEHOLDER',
        'bundled': true,
        'asset_path': 'assets/models/bundled/selfie_segmenter.tflite',
        'purpose': 'MediaPipe Selfie Segmentation',
      };
      final descriptor = ModelDescriptor.fromJson(
        Map<String, dynamic>.from(jsonStr),
      );
      expect(descriptor.id, 'selfie_segmenter');
      expect(descriptor.version, '1.0');
      expect(descriptor.runtime, ModelRuntime.mlkit);
      expect(descriptor.sizeBytes, 524288);
      expect(descriptor.sha256, 'PLACEHOLDER');
      expect(descriptor.bundled, true);
      expect(descriptor.assetPath,
          'assets/models/bundled/selfie_segmenter.tflite');
      expect(descriptor.url, isNull);
    });

    test('downloadable ONNX descriptor parses from manifest JSON', () {
      final descriptor = ModelDescriptor.fromJson(const {
        'id': 'lama_inpaint',
        'version': '1.0',
        'runtime': 'onnx',
        'size_bytes': 218103808,
        'sha256': 'abc123',
        'bundled': false,
        'url': 'https://example.com/lama.onnx',
        'purpose': 'LaMa inpainting',
      });
      expect(descriptor.runtime, ModelRuntime.onnx);
      expect(descriptor.bundled, false);
      expect(descriptor.url, 'https://example.com/lama.onnx');
      expect(descriptor.assetPath, isNull);
    });

    test('round-trip JSON preserves all fields', () {
      const source = ModelDescriptor(
        id: 'test',
        version: '2.0',
        runtime: ModelRuntime.litert,
        sizeBytes: 1024,
        sha256: 'deadbeef',
        bundled: false,
        url: 'https://example.com/test.tflite',
        purpose: 'Test model',
      );
      final roundTrip = ModelDescriptor.fromJson(source.toJson());
      expect(roundTrip, source);
    });

    test('sizeDisplay formats correctly', () {
      expect(_descriptorWithSize(512).sizeDisplay, '1 KB');
      expect(_descriptorWithSize(1024).sizeDisplay, '1 KB');
      expect(_descriptorWithSize(1024 * 1024).sizeDisplay, '1.0 MB');
      expect(_descriptorWithSize(3.5 * 1024 * 1024 ~/ 1).sizeDisplay, '3.5 MB');
      expect(_descriptorWithSize(50 * 1024 * 1024).sizeDisplay, '50 MB');
      expect(_descriptorWithSize(208 * 1024 * 1024).sizeDisplay, '208 MB');
    });
  });
}

ModelDescriptor _descriptorWithSize(int bytes) => ModelDescriptor(
      id: 'x',
      version: '1',
      runtime: ModelRuntime.mlkit,
      sizeBytes: bytes,
      sha256: '',
      bundled: true,
    );
