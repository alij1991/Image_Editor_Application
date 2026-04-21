import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../ai/models/model_cache.dart';
import '../ai/models/model_downloader.dart';
import '../ai/models/model_manifest.dart';
import '../ai/models/model_registry.dart';
import '../ai/runtime/litert_runtime.dart';
import '../ai/runtime/ort_runtime.dart';
import '../ai/services/bg_removal/bg_removal_factory.dart';
import '../bootstrap.dart';
import '../core/memory/memory_budget.dart';
import '../engine/proxy/proxy_manager.dart';
import '../features/editor/presentation/notifiers/editor_notifier.dart';
import '../features/editor/presentation/notifiers/editor_state.dart';

/// The bootstrap result is injected at runApp time via a provider override.
/// Tests can provide their own BootstrapResult without running bootstrap().
final bootstrapResultProvider = Provider<BootstrapResult>((ref) {
  throw UnimplementedError(
    'bootstrapResultProvider must be overridden at app startup '
    '(see main.dart). In tests, override it with a fake BootstrapResult.',
  );
});

/// The device-aware memory budget.
final memoryBudgetProvider = Provider<MemoryBudget>((ref) {
  return ref.watch(bootstrapResultProvider).budget;
});

/// A single ProxyManager shared by the whole app. Keeps a small LRU of
/// decoded preview images.
final proxyManagerProvider = Provider<ProxyManager>((ref) {
  final budget = ref.watch(memoryBudgetProvider);
  final manager = ProxyManager(budget: budget);
  ref.onDispose(manager.evictAll);
  return manager;
});

/// The root editor state. Holds the current session (proxy + pipeline +
/// history) or `null` when no image is loaded.
final editorNotifierProvider =
    StateNotifierProvider<EditorNotifier, EditorState>((ref) {
  final manager = ref.watch(proxyManagerProvider);
  return EditorNotifier(proxyManager: manager);
});

// ----- AI subsystem providers -----------------------------------------------
//
// These read from the BootstrapResult so the whole graph has a single
// source of truth. Tests override `bootstrapResultProvider` with a
// fake that supplies stub runtimes and an empty manifest.

/// Static manifest of every on-device ML model the app knows about.
final modelManifestProvider = Provider<ModelManifest>((ref) {
  return ref.watch(bootstrapResultProvider).modelManifest;
});

/// Non-null when the AI bootstrap ran in degraded mode (manifest
/// load failed or returned empty). The Model Manager sheet reads
/// this to surface a banner — otherwise the user only discovers the
/// problem by tapping an AI feature that silently does nothing.
final manifestDegradationProvider =
    Provider<BootstrapDegradation?>((ref) {
  return ref.watch(bootstrapResultProvider).degradation;
});

/// sqflite-indexed disk cache of downloaded model files. Exposed
/// directly (in addition to via [modelRegistryProvider]) so the
/// Model Manager can query live status and delete individual entries
/// without going through the registry's resolve-or-null signature.
final modelCacheProvider = Provider<ModelCache>((ref) {
  return ref.watch(bootstrapResultProvider).modelCache;
});

/// Combined manifest + on-disk cache resolver.
final modelRegistryProvider = Provider<ModelRegistry>((ref) {
  return ref.watch(bootstrapResultProvider).modelRegistry;
});

/// Shared dio-backed downloader with in-flight cancel tokens.
final modelDownloaderProvider = Provider<ModelDownloader>((ref) {
  return ref.watch(bootstrapResultProvider).modelDownloader;
});

/// LiteRT (TFLite) runtime — used by Real-ESRGAN, Magenta, etc.
final liteRtRuntimeProvider = Provider<LiteRtRuntime>((ref) {
  return ref.watch(bootstrapResultProvider).liteRtRuntime;
});

/// ONNX Runtime — used by RMBG, MODNet, LaMa, etc.
final ortRuntimeProvider = Provider<OrtRuntime>((ref) {
  return ref.watch(bootstrapResultProvider).ortRuntime;
});

/// Factory that builds concrete [BgRemovalStrategy] instances for
/// MediaPipe / MODNet / RMBG, resolving model dependencies through
/// the registry.
final bgRemovalFactoryProvider = Provider<BgRemovalFactory>((ref) {
  return ref.watch(bootstrapResultProvider).bgRemovalFactory;
});
