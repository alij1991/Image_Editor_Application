import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:logger/logger.dart';

import 'ai/models/model_cache.dart';
import 'ai/models/model_downloader.dart';
import 'ai/models/model_manifest.dart';
import 'ai/models/model_registry.dart';
import 'ai/runtime/delegate_selector.dart';
import 'ai/runtime/litert_runtime.dart';
import 'ai/runtime/ort_runtime.dart';
import 'ai/services/bg_removal/bg_removal_factory.dart';
import 'core/logging/app_logger.dart';
import 'core/memory/image_cache_policy.dart';
import 'core/memory/memory_budget.dart';
import 'engine/rendering/shader_keys.dart';
import 'engine/rendering/shader_registry.dart';

final _log = AppLogger('Bootstrap');

/// Global initialization invoked once from [main] before [runApp].
///
/// Responsibilities:
/// - Configure the logger (level depends on build mode).
/// - Probe the device and apply the memory budget (constrains Flutter's
///   image cache to mitigate Impeller issue #178264).
/// - Pre-warm the shader registry with every shader the app ships so the
///   first slider drag doesn't hit a compile-time stall.
/// - Install a crash reporter for unhandled Flutter errors.
Future<BootstrapResult> bootstrap() async {
  AppLogger.level = kReleaseMode ? Level.warning : Level.debug;
  final logger = Logger();
  _log.i('starting', {
    'release': kReleaseMode,
    'profile': kProfileMode,
    'debug': kDebugMode,
  });

  FlutterError.onError = (details) {
    FlutterError.presentError(details);
    _log.e(
      'FlutterError caught',
      error: details.exception,
      stackTrace: details.stack,
    );
  };

  final budget = await MemoryBudget.probe();
  _log.i('memory budget', {
    'totalRamMB': budget.totalPhysicalRamBytes ~/ (1024 * 1024),
    'imageCacheMB': budget.imageCacheMaxBytes ~/ (1024 * 1024),
    'previewLongEdge': budget.previewLongEdge,
    'maxRamMementos': budget.maxRamMementos,
  });

  final cachePolicy = ImageCachePolicy(budget: budget, logger: logger)..apply();

  // Pre-warm every shader asset so the first drag doesn't stall.
  unawaited(ShaderRegistry.instance.preload(ShaderKeys.all));

  // ----- AI subsystem -------------------------------------------------------
  //
  // Load the manifest, open the sqflite cache, and construct the two
  // runtime handles (LiteRT + ORT). These are lightweight: the ML
  // interpreter isn't loaded until a feature actually requests a
  // session, and the sqflite connection is opened lazily. We still
  // guard with try/catch so an asset-load failure doesn't block the
  // editor from starting — bg removal will fall back to MediaPipe
  // (bundled) if the registry is degraded.
  //
  // Degradation signal: `loadFromAssets` currently swallows errors
  // internally and returns an empty manifest. We inspect the result
  // and also wrap the call in our own try/catch so callers get an
  // explicit non-null [BootstrapDegradation] whenever AI features are
  // about to fail — the Model Manager banner reads that signal so the
  // user learns before tapping an AI button that does nothing.
  ModelManifest manifest;
  Object? manifestLoadError;
  try {
    manifest = await ModelManifest.loadFromAssets();
  } catch (e, st) {
    _log.e('manifest load failed, using empty', error: e, stackTrace: st);
    manifest = ModelManifest(const []);
    manifestLoadError = e;
  }
  final degradation = detectManifestDegradation(
    manifest,
    loadError: manifestLoadError,
  );
  if (degradation != null) {
    _log.w('bootstrap degraded', {
      'reason': degradation.reason.name,
      'message': degradation.message,
    });
  }
  final modelCache = ModelCache();
  final modelRegistry = ModelRegistry(manifest: manifest, cache: modelCache);
  final modelDownloader = ModelDownloader();
  final delegateSelector = DelegateSelector(_probeDeviceCapabilities());
  final liteRtRuntime = LiteRtRuntime(selector: delegateSelector);
  final ortRuntime = OrtRuntime(selector: delegateSelector);
  final bgRemovalFactory = BgRemovalFactory(
    registry: modelRegistry,
    liteRtRuntime: liteRtRuntime,
    ortRuntime: ortRuntime,
  );
  _log.i('ai subsystem ready', {
    'manifestModels': manifest.descriptors.length,
    'degraded': degradation != null,
    'delegateChain': delegateSelector.preferredChain().map((d) => d.label).toList(),
  });

  _log.i('bootstrap complete');
  return BootstrapResult(
    logger: logger,
    budget: budget,
    cachePolicy: cachePolicy,
    modelManifest: manifest,
    modelCache: modelCache,
    modelRegistry: modelRegistry,
    modelDownloader: modelDownloader,
    liteRtRuntime: liteRtRuntime,
    ortRuntime: ortRuntime,
    bgRemovalFactory: bgRemovalFactory,
    degradation: degradation,
  );
}

/// Classify whether the bootstrap's AI surface is degraded. Pure
/// helper so tests don't have to run the full [bootstrap] to exercise
/// the detection logic.
///
/// Returns `null` when the manifest is healthy (non-empty + no load
/// error). Returns a reason otherwise. The caller is responsible for
/// surfacing the degradation — this function only classifies.
BootstrapDegradation? detectManifestDegradation(
  ModelManifest manifest, {
  Object? loadError,
}) {
  if (loadError != null) {
    return const BootstrapDegradation(
      reason: DegradationReason.manifestLoadFailed,
      message: 'The AI model manifest could not be read. '
          'Reinstall the app to restore AI features.',
    );
  }
  if (manifest.descriptors.isEmpty) {
    return const BootstrapDegradation(
      reason: DegradationReason.manifestEmpty,
      message: 'The AI model manifest loaded empty. '
          'AI features will be unavailable until the manifest is restored.',
    );
  }
  return null;
}

/// Non-fatal bootstrap-time signal that the AI subsystem started in
/// degraded mode. The app keeps running — the editor and every
/// non-AI feature work normally — but any code that resolves a model
/// through the manifest will find nothing, and AI buttons will
/// produce "AI unavailable" on tap.
///
/// Exposed via [manifestDegradationProvider] so the Model Manager
/// sheet can render a banner that names the cause instead of the user
/// hunting through AI features that silently do nothing.
@immutable
class BootstrapDegradation {
  const BootstrapDegradation({
    required this.reason,
    required this.message,
  });

  final DegradationReason reason;
  final String message;
}

enum DegradationReason {
  /// `ModelManifest.loadFromAssets` threw — the asset bundle is
  /// missing, corrupt, or the JSON decoder rejected it.
  manifestLoadFailed,

  /// The load succeeded but yielded zero descriptors. Either the
  /// shipped manifest is empty (dev shipping error) or every
  /// descriptor was malformed and skipped.
  manifestEmpty,
}

/// Probe the current device's accelerator support at a glance. Phase
/// 9c keeps this conservative — NNAPI/CoreML are flagged as available
/// on their host platforms so the `preferredChain()` surfaces them,
/// but actual delegate construction still falls back gracefully when
/// a given op set isn't supported.
DeviceCapabilities _probeDeviceCapabilities() {
  if (Platform.isIOS) {
    return const DeviceCapabilities(
      platform: TargetPlatform.iOS,
      supportsGpuDelegate: true,
      supportsNnapi: false,
      supportsCoreMl: true,
    );
  }
  if (Platform.isAndroid) {
    return const DeviceCapabilities(
      platform: TargetPlatform.android,
      supportsGpuDelegate: true,
      supportsNnapi: true,
      supportsCoreMl: false,
    );
  }
  return DeviceCapabilities.conservative;
}

class BootstrapResult {
  const BootstrapResult({
    required this.logger,
    required this.budget,
    required this.cachePolicy,
    required this.modelManifest,
    required this.modelCache,
    required this.modelRegistry,
    required this.modelDownloader,
    required this.liteRtRuntime,
    required this.ortRuntime,
    required this.bgRemovalFactory,
    this.degradation,
  });
  final Logger logger;
  final MemoryBudget budget;
  final ImageCachePolicy cachePolicy;
  final ModelManifest modelManifest;
  final ModelCache modelCache;
  final ModelRegistry modelRegistry;
  final ModelDownloader modelDownloader;
  final LiteRtRuntime liteRtRuntime;
  final OrtRuntime ortRuntime;
  final BgRemovalFactory bgRemovalFactory;

  /// Non-null when the AI subsystem started in degraded mode. The
  /// Model Manager banner reads this to tell the user something's
  /// wrong at the bundle level before they tap an AI feature.
  final BootstrapDegradation? degradation;
}
