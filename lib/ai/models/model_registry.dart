import '../../core/logging/app_logger.dart';
import 'model_cache.dart';
import 'model_descriptor.dart';
import 'model_manifest.dart';

final _log = AppLogger('ModelRegistry');

/// Top-level resolver for on-device ML models.
///
/// Combines the static [ModelManifest] (which lists every model the
/// app knows about) with the runtime [ModelCache] (which tracks
/// downloaded files) to answer two questions:
///
///   - "Where do I find the file for model id X right now?"
///   - "Do I need to download it first, or is it already bundled /
///     cached on disk?"
///
/// One instance per app. Constructed during bootstrap and shared via
/// Riverpod. Downstream code only needs the descriptor and the
/// resolver method — it never talks to the manifest or cache directly.
class ModelRegistry {
  ModelRegistry({
    required this.manifest,
    required this.cache,
    Set<String>? shippedAssetKeys,
  }) : _shippedAssetKeys = shippedAssetKeys;

  final ModelManifest manifest;
  final ModelCache cache;

  /// XVI.119 — the asset keys that ACTUALLY shipped in the app bundle,
  /// loaded once from [AssetManifest] at bootstrap and injected here.
  /// When non-null, [resolve] reports a `bundled` model as UNAVAILABLE
  /// if its `assetPath` isn't in this set.
  ///
  /// Why this is needed: `pubspec.yaml` declares the whole
  /// `assets/models/bundled/` directory, so a model file that was never
  /// committed is simply absent from the bundle — yet its manifest entry
  /// can still carry `bundled: true` (the dead `espcn_3x` / `u2netp`
  /// entries were exactly this). Without this guard `resolve` handed back
  /// an asset path that `rootBundle.load` only throws on at runtime, so a
  /// missing model looked "available" right up until the user tapped the
  /// feature.
  ///
  /// Null = skip the check (legacy / unit-test construction, or the asset
  /// manifest failed to load) so behaviour is unchanged in that case.
  final Set<String>? _shippedAssetKeys;

  /// Look up a descriptor by id. Returns null if the id isn't in the
  /// manifest.
  ModelDescriptor? descriptor(String id) => manifest.byId(id);

  /// Resolve a model id to a local filesystem path, or null if the
  /// model needs to be downloaded first. Bundled models always
  /// resolve to their asset path (callers treat that as a Flutter
  /// asset). Downloaded models resolve via the sqflite cache.
  Future<ResolvedModel?> resolve(String id) async {
    final d = descriptor(id);
    if (d == null) {
      _log.w('unknown model id', {'id': id});
      return null;
    }
    if (d.bundled) {
      final assetPath = d.assetPath;
      if (assetPath == null || assetPath.isEmpty) {
        _log.w('bundled descriptor missing assetPath', {'id': id});
        return null;
      }
      // XVI.119 — verify the asset really shipped before claiming the
      // model is available. A `bundled:true` entry whose file was never
      // committed must report unavailable, not hand back a path that
      // fails only at load time.
      final shipped = _shippedAssetKeys;
      if (shipped != null && !shipped.contains(assetPath)) {
        _log.w('bundled asset declared but not in app bundle — unavailable',
            {'id': id, 'asset': assetPath});
        return null;
      }
      _log.d('resolve bundled', {'id': id, 'asset': assetPath});
      return ResolvedModel(
        descriptor: d,
        kind: ResolvedKind.bundled,
        localPath: assetPath,
      );
    }
    final entry = await cache.get(id);
    if (entry == null) {
      _log.d('resolve missing', {'id': id});
      return null;
    }
    // Version mismatch (e.g. we shipped a newer version in the
    // manifest but the user's cached copy is old) → evict and require
    // re-download.
    if (entry.version != d.version) {
      _log.w('version mismatch, evicting',
          {'id': id, 'cached': entry.version, 'manifest': d.version});
      await cache.delete(id);
      return null;
    }
    _log.d('resolve cached', {'id': id, 'path': entry.path});
    return ResolvedModel(
      descriptor: d,
      kind: ResolvedKind.cached,
      localPath: entry.path,
    );
  }

  /// True if the model is currently usable without a network fetch.
  Future<bool> isAvailable(String id) async {
    final resolved = await resolve(id);
    return resolved != null;
  }
}

enum ResolvedKind { bundled, cached }

class ResolvedModel {
  const ResolvedModel({
    required this.descriptor,
    required this.kind,
    required this.localPath,
  });

  final ModelDescriptor descriptor;
  final ResolvedKind kind;

  /// Path on disk (for cached) or Flutter asset key (for bundled).
  final String localPath;

  bool get isBundled => kind == ResolvedKind.bundled;
}
