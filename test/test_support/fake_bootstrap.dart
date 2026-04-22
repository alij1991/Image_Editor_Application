import 'package:logger/logger.dart';

import 'package:image_editor/ai/models/model_cache.dart';
import 'package:image_editor/ai/models/model_downloader.dart';
import 'package:image_editor/ai/models/model_manifest.dart';
import 'package:image_editor/ai/models/model_registry.dart';
import 'package:image_editor/ai/runtime/delegate_selector.dart';
import 'package:image_editor/ai/runtime/litert_runtime.dart';
import 'package:image_editor/ai/runtime/ort_runtime.dart';
import 'package:image_editor/ai/services/bg_removal/bg_removal_factory.dart';
import 'package:image_editor/bootstrap.dart';
import 'package:image_editor/core/memory/image_cache_policy.dart';
import 'package:image_editor/core/memory/image_cache_watchdog.dart';
import 'package:image_editor/core/memory/memory_budget.dart';

/// Build a [BootstrapResult] populated with conservative stubs so
/// widget tests can drive the editor without touching the filesystem
/// or a real ML runtime.
///
/// Every field except the memory budget and the shared [Logger] is a
/// no-op / empty fixture. The AI subsystem is wired with an empty
/// manifest and a vanilla [ModelCache] (which lazily opens sqflite in
/// [path_provider] — tests that need a real cache must override
/// those, but the smoke tests in this repo only exercise widgets
/// that never resolve models).
BootstrapResult buildFakeBootstrap({
  ModelManifest? manifest,
  BootstrapDegradation? degradation,
}) {
  const budget = MemoryBudget.conservative;
  final m = manifest ?? ModelManifest(const []);
  final cache = ModelCache();
  final registry = ModelRegistry(manifest: m, cache: cache);
  final downloader = ModelDownloader();
  const selector = DelegateSelector(DeviceCapabilities.conservative);
  final liteRt = LiteRtRuntime(selector: selector);
  final ort = OrtRuntime(selector: selector);
  final factory = BgRemovalFactory(
    registry: registry,
    liteRtRuntime: liteRt,
    ortRuntime: ort,
  );
  final cachePolicy = ImageCachePolicy(budget: budget);
  // Phase V.4: hand the fake a never-started watchdog so widget tests
  // don't register post-frame callbacks that survive the test. Tests
  // that want to exercise the watchdog can override the field or
  // drive the class directly via `advanceOneCheck`.
  final cacheWatchdog = ImageCacheWatchdog(
    isNearBudget: () => false,
    onPurge: () {},
  );
  return BootstrapResult(
    logger: Logger(),
    budget: budget,
    cachePolicy: cachePolicy,
    cacheWatchdog: cacheWatchdog,
    modelManifest: m,
    modelCache: cache,
    modelRegistry: registry,
    modelDownloader: downloader,
    liteRtRuntime: liteRt,
    ortRuntime: ort,
    bgRemovalFactory: factory,
    degradation: degradation,
  );
}
