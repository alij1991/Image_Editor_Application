import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:image_editor/ai/runtime/delegate_selector.dart';

void main() {
  group('DelegateSelector preferredChain', () {
    test('iOS with CoreML prefers CoreML → GPU → XNNPACK → CPU', () {
      const selector = DelegateSelector(DeviceCapabilities(
        platform: TargetPlatform.iOS,
        supportsGpuDelegate: true,
        supportsNnapi: false,
        supportsCoreMl: true,
      ));
      expect(selector.preferredChain(), [
        TfLiteDelegate.coreml,
        TfLiteDelegate.gpu,
        TfLiteDelegate.xnnpack,
        TfLiteDelegate.cpu,
      ]);
    });

    test('iOS without CoreML falls back to GPU → XNNPACK → CPU', () {
      const selector = DelegateSelector(DeviceCapabilities(
        platform: TargetPlatform.iOS,
        supportsGpuDelegate: true,
        supportsNnapi: false,
        supportsCoreMl: false,
      ));
      expect(selector.preferredChain().first, TfLiteDelegate.gpu);
      expect(selector.preferredChain().contains(TfLiteDelegate.coreml), false);
    });

    test('Android with NNAPI prefers NNAPI → GPU → XNNPACK → CPU', () {
      const selector = DelegateSelector(DeviceCapabilities(
        platform: TargetPlatform.android,
        supportsGpuDelegate: true,
        supportsNnapi: true,
        supportsCoreMl: false,
      ));
      expect(selector.preferredChain(), [
        TfLiteDelegate.nnapi,
        TfLiteDelegate.gpu,
        TfLiteDelegate.xnnpack,
        TfLiteDelegate.cpu,
      ]);
    });

    test('conservative caps (all off) → XNNPACK + CPU', () {
      const selector = DelegateSelector(DeviceCapabilities.conservative);
      expect(selector.preferredChain(), [
        TfLiteDelegate.xnnpack,
        TfLiteDelegate.cpu,
      ]);
    });

    test('always ends with CPU fallback', () {
      for (final platform in [
        TargetPlatform.iOS,
        TargetPlatform.android,
        TargetPlatform.macOS,
      ]) {
        final selector = DelegateSelector(DeviceCapabilities(
          platform: platform,
          supportsGpuDelegate: false,
          supportsNnapi: false,
          supportsCoreMl: false,
        ));
        expect(selector.preferredChain().last, TfLiteDelegate.cpu);
      }
    });

    test('ONNX chain has a different execution provider order', () {
      const selector = DelegateSelector(DeviceCapabilities(
        platform: TargetPlatform.android,
        supportsGpuDelegate: true,
        supportsNnapi: true,
        supportsCoreMl: false,
      ));
      final chain = selector.preferredOnnxChain();
      // ONNX Runtime doesn't use TFLite GPU; Android prefers NNAPI +
      // XNNPACK.
      expect(chain, [
        TfLiteDelegate.nnapi,
        TfLiteDelegate.xnnpack,
        TfLiteDelegate.cpu,
      ]);
    });
  });
}
