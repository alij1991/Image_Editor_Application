import 'package:flutter_test/flutter_test.dart';

import 'package:image_editor/ai/models/model_cache.dart';
import 'package:image_editor/ai/models/model_descriptor.dart';
import 'package:image_editor/ai/models/model_manifest.dart';
import 'package:image_editor/ai/models/model_registry.dart';
import 'package:image_editor/ai/runtime/delegate_selector.dart';
import 'package:image_editor/ai/runtime/litert_runtime.dart';
import 'package:image_editor/ai/runtime/ort_runtime.dart';
import 'package:image_editor/ai/services/bg_removal/bg_removal_factory.dart';
import 'package:image_editor/ai/services/bg_removal/bg_removal_strategy.dart';

// Helper intentionally kept — used by future sqflite-backed tests.
// ignore: unused_element
ModelDescriptor _bundled({
  required String id,
  ModelRuntime runtime = ModelRuntime.litert,
}) {
  return ModelDescriptor(
    id: id,
    version: '1.0',
    runtime: runtime,
    sizeBytes: 1024,
    sha256: 'PLACEHOLDER',
    bundled: true,
    assetPath: 'assets/models/bundled/$id.tflite',
    purpose: 'test bundled',
  );
}

// Helper intentionally kept — used by future sqflite-backed tests.
// ignore: unused_element
ModelDescriptor _downloadable({
  required String id,
  ModelRuntime runtime = ModelRuntime.litert,
}) {
  return ModelDescriptor(
    id: id,
    version: '1.0',
    runtime: runtime,
    sizeBytes: 1024,
    sha256: 'PLACEHOLDER',
    bundled: false,
    url: 'https://example.com/$id',
    purpose: 'test downloadable',
  );
}

BgRemovalFactory _buildFactory(ModelManifest manifest) {
  final cache = ModelCache();
  final registry = ModelRegistry(manifest: manifest, cache: cache);
  const selector = DelegateSelector(DeviceCapabilities.conservative);
  return BgRemovalFactory(
    registry: registry,
    liteRtRuntime: LiteRtRuntime(selector: selector),
    ortRuntime: OrtRuntime(selector: selector),
  );
}

void main() {
  group('BgRemovalStrategyKind metadata', () {
    test('mediaPipe has no model id and is not downloadable', () {
      expect(BgRemovalStrategyKind.mediaPipe.modelId, isNull);
      expect(BgRemovalStrategyKind.mediaPipe.isDownloadable, false);
    });

    test('modnet maps to "modnet" model id and is downloadable', () {
      expect(BgRemovalStrategyKind.modnet.modelId, 'modnet');
      expect(BgRemovalStrategyKind.modnet.isDownloadable, true);
    });

    test('rmbg maps to "rmbg_1_4_int8" model id and is downloadable', () {
      expect(BgRemovalStrategyKind.rmbg.modelId, 'rmbg_1_4_int8');
      expect(BgRemovalStrategyKind.rmbg.isDownloadable, true);
    });

    test('rvm maps to "rvm_mobilenetv3_fp32" model id and is downloadable',
        () {
      // Phase XV.1: Robust Video Matting — ONNX fp32, downloadable.
      expect(BgRemovalStrategyKind.rvm.modelId, 'rvm_mobilenetv3_fp32');
      expect(BgRemovalStrategyKind.rvm.isDownloadable, true);
    });

    test('every kind has a distinct user-facing label + description', () {
      final labels =
          BgRemovalStrategyKind.values.map((k) => k.label).toSet();
      final descs =
          BgRemovalStrategyKind.values.map((k) => k.description).toSet();
      expect(labels.length, BgRemovalStrategyKind.values.length);
      expect(descs.length, BgRemovalStrategyKind.values.length);
    });
  });

  group('BgRemovalFactory.availability', () {
    test('mediaPipe is always ready (no model dependency)', () async {
      final factory = _buildFactory(ModelManifest(const []));
      final availability =
          await factory.availability(BgRemovalStrategyKind.mediaPipe);
      expect(availability, BgRemovalAvailability.ready);
    });

    test('unknown manifest returns unknownModel for modnet', () async {
      final factory = _buildFactory(ModelManifest(const []));
      final availability =
          await factory.availability(BgRemovalStrategyKind.modnet);
      expect(availability, BgRemovalAvailability.unknownModel);
    });

    test('unknown manifest returns unknownModel for rmbg', () async {
      final factory = _buildFactory(ModelManifest(const []));
      final availability =
          await factory.availability(BgRemovalStrategyKind.rmbg);
      expect(availability, BgRemovalAvailability.unknownModel);
    });

    // NOTE: The `availability(modnet)` and `availability(rmbg)` paths
    // for *downloadable* (non-bundled) descriptors ultimately call
    // `ModelRegistry.resolve` → `ModelCache.get` → sqflite, which
    // needs a path-provider + ffi sqflite mock that we don't yet have
    // wired up. Those paths are exercised by hand via the editor UI
    // during Phase 9c manual testing. Phase 12 (persistence) will
    // bring in `sqflite_common_ffi` and add a proper fixture.
  });

  group('BgRemovalFactory.create error paths', () {
    test('create(modnet) with empty manifest throws with kind set',
        () async {
      final factory = _buildFactory(ModelManifest(const []));
      expect(
        () => factory.create(BgRemovalStrategyKind.modnet),
        throwsA(
          isA<BgRemovalException>()
              .having((e) => e.kind, 'kind', BgRemovalStrategyKind.modnet)
              .having((e) => e.message, 'message', contains('Unknown model id')),
        ),
      );
    });

    test('create(rmbg) with empty manifest throws with kind set', () async {
      final factory = _buildFactory(ModelManifest(const []));
      expect(
        () => factory.create(BgRemovalStrategyKind.rmbg),
        throwsA(
          isA<BgRemovalException>()
              .having((e) => e.kind, 'kind', BgRemovalStrategyKind.rmbg)
              .having((e) => e.message, 'message', contains('Unknown model id')),
        ),
      );
    });
  });

  group('BgRemovalException', () {
    test('toString includes the kind label when known', () {
      const e = BgRemovalException(
        'boom',
        kind: BgRemovalStrategyKind.modnet,
      );
      expect(e.toString(), contains('BgRemovalException[modnet]'));
      expect(e.toString(), contains('boom'));
    });

    test('toString omits kind when null', () {
      const e = BgRemovalException('boom');
      expect(e.toString(), 'BgRemovalException: boom');
    });

    test('toString includes cause when provided', () {
      const cause = 'MlRuntimeException(stage: load, message: file not found)';
      const e = BgRemovalException(
        'wrap',
        kind: BgRemovalStrategyKind.rmbg,
        cause: cause,
      );
      final s = e.toString();
      expect(s, contains('BgRemovalException[rmbg]'));
      expect(s, contains('wrap'));
      expect(s, contains('caused by'));
      expect(s, contains('file not found'));
    });

    test('cause is null by default', () {
      const e = BgRemovalException('x');
      expect(e.cause, isNull);
    });
  });
}
