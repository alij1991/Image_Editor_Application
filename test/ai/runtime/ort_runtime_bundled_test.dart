import 'package:flutter_test/flutter_test.dart';

import 'package:image_editor/ai/models/model_descriptor.dart';
import 'package:image_editor/ai/models/model_registry.dart';
import 'package:image_editor/ai/runtime/delegate_selector.dart';
import 'package:image_editor/ai/runtime/ml_runtime.dart';
import 'package:image_editor/ai/runtime/ort_runtime.dart';

/// Phase XVI.64 — pin the new bundled-ONNX support in `OrtRuntime`.
///
/// Pre-XVI.64 the `isBundled` branch threw an `MlRuntimeException`
/// with message "Bundled ONNX models are not yet supported by
/// OrtRuntime". XVI.64 ports `LiteRtRuntime`'s `rootBundle.load`
/// → temp-file pattern so bundled `.onnx` models resolve through
/// the same path as bundled `.tflite` models do.
///
/// Full inference round-trip needs a real ONNX file in the asset
/// bundle and isn't unit-testable; what we CAN guard is the error
/// message — the rejection-with-"not yet supported" branch must not
/// fire anymore. With a non-existent asset key, the failure path
/// is now the asset-load step in `rootBundle.load`, surfacing as a
/// "Failed to copy bundled ONNX model" exception.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('OrtRuntime — bundled support (Phase XVI.64)', () {
    test('bundled descriptor with missing asset → copy-failed error', () async {
      final runtime = OrtRuntime(
        selector: const DelegateSelector(DeviceCapabilities.conservative),
      );
      const resolved = ResolvedModel(
        descriptor: ModelDescriptor(
          id: 'phantom_bundled_test',
          version: '0',
          runtime: ModelRuntime.onnx,
          sizeBytes: 1,
          sha256: 'PLACEHOLDER',
          bundled: true,
          assetPath: 'assets/models/bundled/this_does_not_exist.onnx',
        ),
        kind: ResolvedKind.bundled,
        localPath: 'assets/models/bundled/this_does_not_exist.onnx',
      );

      Object? caught;
      try {
        await runtime.load(resolved);
      } catch (e) {
        caught = e;
      }
      expect(caught, isNotNull);
      expect(caught, isA<MlRuntimeException>());
      final msg = (caught as MlRuntimeException).message;
      // Pre-XVI.64 message would have been "not yet supported".
      // Post-XVI.64 the bundled branch is taken; failure surfaces
      // from the asset-load step.
      expect(msg, isNot(contains('not yet supported')));
      expect(
        msg.toLowerCase(),
        anyOf(
          contains('failed to copy bundled'),
          contains('unable to load asset'),
        ),
        reason: 'XVI.64 routes bundled descriptors through the temp-file '
            'copy path; missing-asset failures must surface as a copy or '
            'asset-load error, not the historical "not yet supported".',
      );
    });

    test('wrong-runtime descriptor still throws the wrong-runtime error',
        () async {
      // Sanity check that the unrelated rejection branch (LiteRT
      // model handed to OrtRuntime) still fires — XVI.64 only
      // touched the isBundled branch.
      final runtime = OrtRuntime(
        selector: const DelegateSelector(DeviceCapabilities.conservative),
      );
      const resolved = ResolvedModel(
        descriptor: ModelDescriptor(
          id: 'phantom_wrong_runtime',
          version: '0',
          runtime: ModelRuntime.litert,
          sizeBytes: 1,
          sha256: 'PLACEHOLDER',
          bundled: false,
        ),
        kind: ResolvedKind.cached,
        localPath: '/tmp/this_path_is_not_used',
      );

      Object? caught;
      try {
        await runtime.load(resolved);
      } catch (e) {
        caught = e;
      }
      expect(caught, isA<MlRuntimeException>());
      final msg = (caught as MlRuntimeException).message;
      expect(msg, contains('cannot load litert'));
    });
  });
}
