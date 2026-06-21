import 'package:flutter_test/flutter_test.dart';

import 'package:image_editor/ai/models/model_cache.dart';
import 'package:image_editor/ai/models/model_descriptor.dart';
import 'package:image_editor/ai/models/model_manifest.dart';
import 'package:image_editor/ai/models/model_registry.dart';

/// XVI.119 — ModelRegistry.resolve must not report a bundled model as
/// available when its asset was never shipped (a `bundled:true` manifest
/// entry whose file isn't in the app bundle — e.g. the dead espcn_3x /
/// u2netp entries). The `shippedAssetKeys` set, injected from
/// AssetManifest at bootstrap, is the existence gate. The bundled branch
/// resolves before any cache I/O, so ModelCache() is never opened here.
ModelDescriptor _bundled(String id, String assetPath) => ModelDescriptor(
      id: id,
      version: '1.0',
      runtime: ModelRuntime.litert,
      sizeBytes: 1,
      sha256: 'PLACEHOLDER',
      bundled: true,
      assetPath: assetPath,
    );

void main() {
  ModelRegistry build({
    required List<ModelDescriptor> models,
    Set<String>? shipped,
  }) =>
      ModelRegistry(
        manifest: ModelManifest(models),
        cache: ModelCache(),
        shippedAssetKeys: shipped,
      );

  group('ModelRegistry bundled-asset existence (XVI.119)', () {
    test('bundled model whose asset is NOT shipped resolves unavailable',
        () async {
      final reg = build(
        shipped: {'assets/models/bundled/present.tflite'},
        models: [_bundled('ghost', 'assets/models/bundled/ghost.tflite')],
      );
      expect(await reg.resolve('ghost'), isNull);
      expect(await reg.isAvailable('ghost'), isFalse);
    });

    test('bundled model whose asset IS shipped resolves available', () async {
      final reg = build(
        shipped: {'assets/models/bundled/present.tflite'},
        models: [_bundled('real', 'assets/models/bundled/present.tflite')],
      );
      final resolved = await reg.resolve('real');
      expect(resolved, isNotNull);
      expect(resolved!.isBundled, isTrue);
      expect(resolved.localPath, 'assets/models/bundled/present.tflite');
    });

    test('null shippedAssetKeys skips the check (backward compatible)',
        () async {
      final reg = build(
        shipped: null,
        models: [_bundled('trust', 'assets/models/bundled/whatever.tflite')],
      );
      expect(await reg.resolve('trust'), isNotNull);
    });

    test('unknown id resolves null regardless of the set', () async {
      final reg = build(shipped: const {}, models: const []);
      expect(await reg.resolve('nope'), isNull);
    });
  });
}
