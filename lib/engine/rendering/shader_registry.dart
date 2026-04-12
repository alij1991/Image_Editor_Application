import 'dart:ui' as ui;

import '../../core/logging/app_logger.dart';

final _log = AppLogger('ShaderRegistry');

/// Lazily loads and caches [ui.FragmentProgram] instances by asset key.
///
/// The blueprint calls out shader compilation as a hot path — Flutter's
/// Impeller compiles shaders at build time (SPIR-V), but the
/// `FragmentProgram.fromAsset` call still reads the compiled binary from
/// the asset bundle on first use. Caching avoids repeated reads.
///
/// Thread safety: this class is main-isolate only (shaders are GPU
/// resources that cannot be created in a plain isolate).
class ShaderRegistry {
  ShaderRegistry._();

  static final ShaderRegistry instance = ShaderRegistry._();

  final Map<String, ui.FragmentProgram> _programs = {};
  final Map<String, Future<ui.FragmentProgram>> _loading = {};

  int get cachedCount => _programs.length;

  /// Get the cached program for [assetKey] if available.
  ui.FragmentProgram? getCached(String assetKey) => _programs[assetKey];

  /// Load (or return the cached) [ui.FragmentProgram] for the given asset.
  Future<ui.FragmentProgram> load(String assetKey) {
    final cached = _programs[assetKey];
    if (cached != null) return Future.value(cached);
    final pending = _loading[assetKey];
    if (pending != null) return pending;

    _log.d('loading', {'asset': assetKey});
    final future = _loadFromAsset(assetKey);
    _loading[assetKey] = future;
    return future;
  }

  /// Pre-warm the cache by loading a list of shaders in parallel.
  /// Call this once on the editor page's first build to avoid jank when
  /// a new adjustment type is tapped for the first time.
  Future<void> preload(Iterable<String> assetKeys) async {
    _log.i('preload start', {'count': assetKeys.length});
    final stopwatch = Stopwatch()..start();
    try {
      await Future.wait(assetKeys.map(load));
      stopwatch.stop();
      _log.i('preload complete',
          {'ms': stopwatch.elapsedMilliseconds, 'cached': _programs.length});
    } catch (e, st) {
      _log.e('preload failed', error: e, stackTrace: st);
      rethrow;
    }
  }

  Future<ui.FragmentProgram> _loadFromAsset(String assetKey) async {
    try {
      final program = await ui.FragmentProgram.fromAsset(assetKey);
      _programs[assetKey] = program;
      _loading.remove(assetKey);
      _log.d('loaded', {'asset': assetKey});
      return program;
    } catch (e, st) {
      _loading.remove(assetKey);
      _log.e('load failed',
          error: e, stackTrace: st, data: {'asset': assetKey});
      rethrow;
    }
  }

  /// Drop every cached program. Call on memory pressure warnings — next
  /// shader use will re-load from the asset bundle.
  void dispose() {
    _log.i('dispose', {'dropping': _programs.length});
    _programs.clear();
    _loading.clear();
  }
}
