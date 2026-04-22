import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:image_editor/ai/models/model_descriptor.dart';
import 'package:image_editor/ai/models/model_manifest.dart';
import 'package:image_editor/ai/services/bg_removal/bg_removal_factory.dart';
import 'package:image_editor/ai/services/bg_removal/bg_removal_strategy.dart';
import 'package:image_editor/bootstrap.dart';
import 'package:image_editor/di/providers.dart';

import '../test_support/fake_bootstrap.dart';

class _TmpPathProvider extends PathProviderPlatform
    with MockPlatformInterfaceMixin {
  _TmpPathProvider(this.tmp);
  final String tmp;
  @override
  Future<String?> getTemporaryPath() async => tmp;
  @override
  Future<String?> getApplicationDocumentsPath() async => tmp;
  @override
  Future<String?> getApplicationSupportPath() async => tmp;
  @override
  Future<String?> getApplicationCachePath() async => tmp;
}

/// IX.C.2 — end-to-end AI wiring from `BootstrapResult` through
/// Riverpod providers to the concrete factory + availability resolver.
/// Exercises the full graph without running `bootstrap()` itself.
/// Validates: providers chain correctly, factory resolves manifest
/// lookups, availability reports the expected state per strategy.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  late Directory tmp;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('bootstrap_ai_wiring');
    PathProviderPlatform.instance = _TmpPathProvider(tmp.path);
  });

  tearDown(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  ModelManifest realishManifest() => ModelManifest([
        const ModelDescriptor(
          id: 'rmbg_1_4_int8',
          version: '1.0',
          runtime: ModelRuntime.onnx,
          sizeBytes: 44 * 1024 * 1024,
          sha256: 'deadbeef',
          bundled: false,
          url: 'https://example.invalid/rmbg.onnx',
        ),
        const ModelDescriptor(
          id: 'modnet',
          version: '1.0',
          runtime: ModelRuntime.onnx,
          sizeBytes: 7 * 1024 * 1024,
          sha256: 'cafebabe',
          bundled: false,
          url: 'https://example.invalid/modnet.onnx',
        ),
        const ModelDescriptor(
          id: 'u2netp',
          version: '1.0',
          runtime: ModelRuntime.litert,
          sizeBytes: 5 * 1024 * 1024,
          sha256: 'f00dface',
          bundled: true,
          assetPath: 'assets/models/bundled/u2netp.tflite',
        ),
      ]);

  ProviderContainer containerFor(BootstrapResult bs) {
    return ProviderContainer(overrides: [
      bootstrapResultProvider.overrideWithValue(bs),
    ]);
  }

  test('provider graph resolves every surface the editor + AI features use',
      () {
    final bs = buildFakeBootstrap(manifest: realishManifest());
    final container = containerFor(bs);
    addTearDown(container.dispose);

    // Each of these would throw if the bootstrap wiring were missing a
    // field or the provider contract drifted.
    expect(container.read(bootstrapResultProvider), same(bs));
    expect(container.read(memoryBudgetProvider), same(bs.budget));
    expect(container.read(modelManifestProvider), same(bs.modelManifest));
    expect(container.read(modelCacheProvider), same(bs.modelCache));
    expect(container.read(modelRegistryProvider), same(bs.modelRegistry));
    expect(container.read(modelDownloaderProvider),
        same(bs.modelDownloader));
    expect(container.read(liteRtRuntimeProvider), same(bs.liteRtRuntime));
    expect(container.read(ortRuntimeProvider), same(bs.ortRuntime));
    expect(container.read(bgRemovalFactoryProvider),
        same(bs.bgRemovalFactory));
    expect(container.read(manifestDegradationProvider), bs.degradation);
  });

  test('factory resolves manifest entries for every declared model id',
      () async {
    final bs = buildFakeBootstrap(manifest: realishManifest());
    final container = containerFor(bs);
    addTearDown(container.dispose);

    final registry = container.read(modelRegistryProvider);
    for (final id in ['rmbg_1_4_int8', 'modnet', 'u2netp']) {
      expect(registry.descriptor(id), isNotNull,
          reason: 'registry must resolve manifest entry $id');
    }
    expect(registry.descriptor('does-not-exist'), isNull);
  });

  test(
      'factory.availability: MediaPipe always ready, downloaded ones '
      'report downloadRequired before download', () async {
    final bs = buildFakeBootstrap(manifest: realishManifest());
    final container = containerFor(bs);
    addTearDown(container.dispose);
    final factory = container.read(bgRemovalFactoryProvider);

    // Bundled / always-available strategy.
    expect(
      await factory.availability(BgRemovalStrategyKind.mediaPipe),
      BgRemovalAvailability.ready,
    );
    // Downloadable strategies — no cache rows, so downloadRequired.
    expect(
      await factory.availability(BgRemovalStrategyKind.modnet),
      BgRemovalAvailability.downloadRequired,
    );
    expect(
      await factory.availability(BgRemovalStrategyKind.rmbg),
      BgRemovalAvailability.downloadRequired,
    );
    // VIII.12 — generalOffline probes rootBundle; missing asset in
    // test env means downloadRequired (the picker then shows
    // "Unavailable").
    expect(
      await factory.availability(BgRemovalStrategyKind.generalOffline),
      BgRemovalAvailability.downloadRequired,
    );
  });

  test('factory.availability reports unknownModel when manifest lacks entry',
      () async {
    // Manifest missing the rmbg entry entirely.
    final bs = buildFakeBootstrap(
      manifest: ModelManifest([
        const ModelDescriptor(
          id: 'modnet',
          version: '1.0',
          runtime: ModelRuntime.onnx,
          sizeBytes: 7 * 1024 * 1024,
          sha256: '',
          bundled: false,
        ),
      ]),
    );
    final container = containerFor(bs);
    addTearDown(container.dispose);
    final factory = container.read(bgRemovalFactoryProvider);

    expect(
      await factory.availability(BgRemovalStrategyKind.rmbg),
      BgRemovalAvailability.unknownModel,
    );
  });

  test('degradation signal propagates through the provider', () {
    const d = BootstrapDegradation(
      reason: DegradationReason.manifestEmpty,
      message: 'test degradation',
    );
    final bs = buildFakeBootstrap(degradation: d);
    final container = containerFor(bs);
    addTearDown(container.dispose);
    expect(container.read(manifestDegradationProvider), d);
  });

  test('null degradation stays null through the provider', () {
    final bs = buildFakeBootstrap();
    final container = containerFor(bs);
    addTearDown(container.dispose);
    expect(container.read(manifestDegradationProvider), isNull);
  });
}
