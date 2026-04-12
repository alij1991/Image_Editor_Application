import 'dart:ui' as ui;

import 'edit_pipeline.dart';

/// Tracks the minimum operation index that must be re-rendered when a
/// pipeline changes, and caches intermediate [ui.Image] results by op id so
/// the preview path never re-renders from the original unless absolutely
/// required.
///
/// The contract is:
///   - call [notifyPipelineChanged] whenever the pipeline is mutated
///   - the lowest changed index is captured in [firstDirtyIndex]
///   - [cache] stores `opId -> ui.Image` for every op that has a stable
///     output. `opId` is the [EditOperation.id] of the op whose output
///     the image represents (i.e. the cached image is the result AFTER
///     applying that op to its predecessor).
///   - when an op is enabled/disabled or its parameters change, the dirty
///     index moves to that op and every cached image at or after it is
///     disposed.
class DirtyTracker {
  DirtyTracker();

  EditPipeline? _lastPipeline;
  int _firstDirtyIndex = 0;
  final Map<String, ui.Image> _cache = {};

  /// The lowest operation index that needs rendering. 0 means "start from
  /// the original proxy".
  int get firstDirtyIndex => _firstDirtyIndex;

  /// Number of cached intermediate images currently held.
  int get cacheSize => _cache.length;

  /// Returns the cached image for [opId], or null if none.
  ui.Image? cachedOutputFor(String opId) => _cache[opId];

  /// Store a rendered intermediate for [opId]. Disposes any previous
  /// image held for the same id.
  void cacheOutput(String opId, ui.Image image) {
    final prev = _cache.remove(opId);
    prev?.dispose();
    _cache[opId] = image;
  }

  /// Compute the dirty index given a new pipeline and the previous one.
  /// Disposes cache entries for ops at or after the dirty index.
  void notifyPipelineChanged(EditPipeline next) {
    final prev = _lastPipeline;
    if (prev == null) {
      _firstDirtyIndex = 0;
      _disposeAtOrAfter(0, next);
      _lastPipeline = next;
      return;
    }

    final newOps = next.operations;
    final oldOps = prev.operations;
    int dirty = _commonPrefixLength(oldOps, newOps);
    _firstDirtyIndex = dirty;
    _disposeAtOrAfter(dirty, next);
    _lastPipeline = next;
  }

  /// Invalidate the cache entirely (for session switches, for example).
  void invalidateAll() {
    for (final img in _cache.values) {
      img.dispose();
    }
    _cache.clear();
    _firstDirtyIndex = 0;
    _lastPipeline = null;
  }

  void _disposeAtOrAfter(int index, EditPipeline next) {
    // Dispose cache entries whose op id no longer appears in positions
    // [index, end] of the new pipeline. Entries for ops that moved earlier
    // or were removed are dropped.
    final stillValidIds = <String>{
      for (int i = 0; i < index; i++) next.operations[i].id,
    };
    final toDispose = <String>[];
    for (final entry in _cache.entries) {
      if (!stillValidIds.contains(entry.key)) {
        toDispose.add(entry.key);
      }
    }
    for (final id in toDispose) {
      _cache.remove(id)?.dispose();
    }
  }

  /// Return the length of the shared prefix between two op lists, where
  /// ops are considered equal if they have the same id AND the same
  /// parameters + enabled flag.
  int _commonPrefixLength(
    List oldOps,
    List newOps,
  ) {
    final limit = oldOps.length < newOps.length ? oldOps.length : newOps.length;
    int i = 0;
    while (i < limit) {
      final a = oldOps[i];
      final b = newOps[i];
      if (a.id != b.id) break;
      if (a.enabled != b.enabled) break;
      if (!_mapEquals(a.parameters, b.parameters)) break;
      if (a.mask != b.mask) break;
      i++;
    }
    return i;
  }

  static bool _mapEquals(Map<String, dynamic> a, Map<String, dynamic> b) {
    if (a.length != b.length) return false;
    for (final k in a.keys) {
      if (!b.containsKey(k)) return false;
      if (a[k] != b[k]) return false;
    }
    return true;
  }
}
