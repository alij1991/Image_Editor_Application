import 'dart:typed_data';

import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../ai/models/model_cache.dart';
import '../ai/models/model_downloader.dart';
import '../ai/models/model_manifest.dart';
import '../ai/models/model_registry.dart';
import '../ai/runtime/litert_runtime.dart';
import '../ai/runtime/ort_runtime.dart';
import '../ai/services/bg_removal/bg_removal_factory.dart';
import '../ai/services/preset_suggest/preset_embedder_service.dart';
import '../ai/services/preset_suggest/preset_suggester.dart';
import '../ai/services/style_transfer/style_vector_cache.dart';
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
  final budget = ref.watch(memoryBudgetProvider);
  return EditorNotifier(proxyManager: manager, memoryBudget: budget);
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

/// Phase V.5: app-wide sha256-keyed disk cache for Magenta
/// style-prediction vectors (`<AppDocs>/style_vectors/<sha>.bin`).
/// Re-applying a custom style to the same reference image skips
/// ML Kit entirely — the cached 100-float32 vector survives app
/// restarts.
final styleVectorCacheProvider = Provider<StyleVectorCache>((ref) {
  return StyleVectorCache();
});

/// Phase XVI.66c — pre-baked embedding library used by the "For You"
/// preset rail. Loaded once on app start from
/// `assets/presets/preset_embeddings.json`. Returns
/// [PresetEmbeddingLibrary.empty] on any failure (missing asset,
/// malformed JSON) so the rail quietly disappears rather than
/// surfacing a parse error to the user.
final presetEmbeddingLibraryProvider =
    FutureProvider<PresetEmbeddingLibrary>((ref) async {
  try {
    final raw = await rootBundle
        .loadString('assets/presets/preset_embeddings.json');
    return PresetEmbeddingLibrary.parse(raw);
  } catch (_) {
    return PresetEmbeddingLibrary.empty;
  }
});

/// Phase XVI.66c — kNN suggester wrapping the loaded library. Returns
/// `null` while the library is still loading or when the bake-time
/// assets aren't shipped (so the rail callers can `?.suggest(...)
/// ?? const []` safely).
final presetSuggesterProvider = Provider<PresetSuggester?>((ref) {
  final libAsync = ref.watch(presetEmbeddingLibraryProvider);
  final lib = libAsync.value;
  if (lib == null || lib.entries.isEmpty) return null;
  return PresetSuggester(library: lib);
});

/// Phase XVI.66c — `Float32List` embedding of the source photo at
/// [sourcePath]. Loads the bundled MobileViT-v2 ONNX, runs one
/// inference, then closes the session (kept short-lived because the
/// model file weighs ~27 MB and the embedding only needs to land
/// once per photo).
///
/// `autoDispose.family` keyed by sourcePath because:
///   * the embedding is photo-specific, so a single global provider
///     would have to be invalidated on every "Open another photo"
///     swap;
///   * autoDispose lets the provider drop its memory when the
///     editor closes, so we don't keep a stale embedding around;
///   * family caches by key, so rebuilding the editor for the same
///     path doesn't re-run the model.
final sourceEmbeddingProvider = FutureProvider.autoDispose
    .family<Float32List, String>((ref, sourcePath) async {
  final registry = ref.read(modelRegistryProvider);
  final ort = ref.read(ortRuntimeProvider);
  final resolved = await registry.resolve(kPresetEmbedderModelId);
  if (resolved == null) {
    throw const PresetEmbedderException(
      'Preset embedder model is not bundled.',
    );
  }
  final session = await ort.load(resolved);
  final service = PresetEmbedderService(session: session);
  try {
    return await service.embedFromPath(sourcePath);
  } finally {
    await service.close();
  }
});

/// Phase XVI.66c — top-N preset suggestions for the source photo.
/// Combines [sourceEmbeddingProvider] (the user's photo embedding)
/// with [presetSuggesterProvider] (the pre-baked library) and
/// returns the ranked list. Returns an empty list on any failure
/// (no library shipped, model load failed, embed failed) so the UI
/// rail just disappears instead of throwing.
final forYouSuggestionsProvider = FutureProvider.autoDispose
    .family<List<PresetSuggestion>, String>((ref, sourcePath) async {
  final suggester = ref.watch(presetSuggesterProvider);
  if (suggester == null) return const [];
  try {
    final embedding =
        await ref.watch(sourceEmbeddingProvider(sourcePath).future);
    return suggester.suggest(queryEmbedding: embedding, k: 5);
  } catch (_) {
    return const [];
  }
});
