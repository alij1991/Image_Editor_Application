import '../../core/logging/app_logger.dart';
import '../../core/memory/memory_budget.dart';
import '../pipeline/preview_proxy.dart';
import 'proxy_cache.dart';

final _log = AppLogger('ProxyManager');

/// Central entry point for obtaining a [PreviewProxy] for any source image.
///
/// Deduplicates concurrent loads (multiple callers asking for the same
/// path while it's still decoding share a single Future), applies the
/// [MemoryBudget] preview long-edge, and manages the LRU cache.
///
/// Phase V.2: the internal [ProxyCache] is sized from
/// `budget.maxProxyEntries` (RAM-tiered: 3 / 5 / 8 for low / mid /
/// high tiers) — previously a flat 3.
class ProxyManager {
  ProxyManager({required this.budget, ProxyCache? cache})
      : _cache = cache ?? ProxyCache(maxEntries: budget.maxProxyEntries);

  final MemoryBudget budget;
  final ProxyCache _cache;
  final Map<String, Future<PreviewProxy>> _inflight = {};

  /// Load (or retrieve) the preview proxy for [sourcePath]. Multiple
  /// concurrent callers get the same future.
  Future<PreviewProxy> obtain(String sourcePath) {
    final cached = _cache.get(sourcePath);
    if (cached != null && cached.isLoaded) {
      _log.d('cache hit', {'path': sourcePath});
      return Future.value(cached);
    }
    final pending = _inflight[sourcePath];
    if (pending != null) {
      _log.d('join inflight', {'path': sourcePath});
      return pending;
    }
    _log.i('load', {'path': sourcePath, 'longEdge': budget.previewLongEdge});
    final future = _load(sourcePath);
    _inflight[sourcePath] = future;
    return future.whenComplete(() => _inflight.remove(sourcePath));
  }

  Future<PreviewProxy> _load(String sourcePath) async {
    final proxy = PreviewProxy(
      sourcePath: sourcePath,
      longEdge: budget.previewLongEdge,
    );
    await proxy.load();
    _cache.put(sourcePath, proxy);
    _log.d('cache put', {'path': sourcePath, 'cacheSize': _cache.length});
    return proxy;
  }

  /// Evict a specific proxy (used when the user closes a project).
  void evict(String sourcePath) {
    _log.d('evict', {'path': sourcePath});
    _cache.remove(sourcePath);
  }

  /// Evict everything (used on memory pressure warnings).
  void evictAll() {
    _log.i('evictAll');
    _cache.clear();
  }
}
