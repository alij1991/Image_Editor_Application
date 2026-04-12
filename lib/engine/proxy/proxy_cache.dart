import 'dart:collection';

import '../pipeline/preview_proxy.dart';

/// LRU cache of [PreviewProxy] instances keyed by source path.
///
/// Kept small (default 3) so the editor never holds more than a handful
/// of decoded originals in memory. When the cache evicts, the evicted
/// proxy is disposed so its `ui.Image` is released immediately.
class ProxyCache {
  ProxyCache({this.maxEntries = 3});

  final int maxEntries;
  final LinkedHashMap<String, PreviewProxy> _entries =
      LinkedHashMap<String, PreviewProxy>();

  int get length => _entries.length;

  PreviewProxy? get(String sourcePath) {
    final p = _entries.remove(sourcePath);
    if (p == null) return null;
    _entries[sourcePath] = p; // move to MRU position
    return p;
  }

  void put(String sourcePath, PreviewProxy proxy) {
    _entries.remove(sourcePath)?.dispose();
    _entries[sourcePath] = proxy;
    while (_entries.length > maxEntries) {
      final oldestKey = _entries.keys.first;
      final evicted = _entries.remove(oldestKey);
      evicted?.dispose();
    }
  }

  void remove(String sourcePath) {
    _entries.remove(sourcePath)?.dispose();
  }

  void clear() {
    for (final p in _entries.values) {
      p.dispose();
    }
    _entries.clear();
  }
}
