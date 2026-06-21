import 'package:flutter/services.dart' show AssetManifest, rootBundle;
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

  // Production-correctness guard. The unit tests above use a hand-built
  // shippedAssetKeys set, so they CANNOT catch a key-format mismatch
  // between AssetManifest.listAssets() and a descriptor's assetPath. If
  // those formats diverged, bootstrap would mark EVERY bundled model
  // unavailable and silently break all AI features. This loads the real
  // shipped AssetManifest + manifest.json and pins the invariant.
  group('AssetManifest key format vs manifest assetPaths (XVI.119)', () {
    TestWidgetsFlutterBinding.ensureInitialized();

    late Set<String> shipped;
    late ModelManifest manifest;
    setUpAll(() async {
      final am = await AssetManifest.loadFromAssetBundle(rootBundle);
      shipped = am.listAssets().toSet();
      manifest = ModelManifest.parse(
        await rootBundle.loadString('assets/models/manifest.json'),
      );
    });

    test('a known committed bundled asset IS in the AssetManifest', () {
      // efficientdet_lite0.tflite is committed (object detection). If the
      // key format matched nothing this would fail — the canary.
      expect(
        shipped.contains('assets/models/bundled/efficientdet_lite0.tflite'),
        isTrue,
        reason: 'AssetManifest key format must match the bundled assetPath',
      );
    });

    test('every bundled model resolves iff its asset actually shipped',
        () async {
      final registry = ModelRegistry(
        manifest: manifest,
        cache: ModelCache(),
        shippedAssetKeys: shipped,
      );
      var shippedCount = 0;
      for (final d in manifest.descriptors.where((d) => d.bundled)) {
        final path = d.assetPath;
        if (path == null || path.isEmpty) continue;
        final present = shipped.contains(path);
        final resolved = await registry.resolve(d.id);
        expect(resolved != null, present,
            reason: '${d.id}: resolve nullability must match whether '
                '$path is in the shipped AssetManifest');
        if (present) shippedCount++;
      }
      // Sanity: the real app ships multiple bundled models, so the check
      // is exercising the positive path (not vacuously passing because
      // everything is "missing").
      expect(shippedCount, greaterThanOrEqualTo(5),
          reason: 'real bundled models must resolve as available');
    });

    test('u2netp (manifest tombstone, asset never committed) is unavailable',
        () async {
      final d = manifest.byId('u2netp');
      if (d == null) return; // tolerate a future prune
      expect(shipped.contains(d.assetPath), isFalse);
      final registry = ModelRegistry(
        manifest: manifest,
        cache: ModelCache(),
        shippedAssetKeys: shipped,
      );
      expect(await registry.resolve('u2netp'), isNull);
    });
  });
}
