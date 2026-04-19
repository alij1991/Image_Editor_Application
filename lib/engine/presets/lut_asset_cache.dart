import 'dart:ui' as ui;

import 'package:flutter/services.dart' show rootBundle;

import '../../core/logging/app_logger.dart';

final _log = AppLogger('LutAssetCache');

/// Lazily decodes 3D LUT PNG assets (the kind baked by
/// `tool/bake_luts.dart`) into shared [ui.Image]s the LUT shader pass
/// can sample.
///
/// Usage from the pipeline-to-passes path:
///
///   final lut = LutAssetCache.instance.getCached(assetPath);
///   if (lut == null) {
///     LutAssetCache.instance.load(assetPath);
///     // skip the pass this frame; next pipeline rebuild picks it up
///   } else {
///     passes.add(Lut3dShader(lut: lut, intensity: ...).toPass());
///   }
///
/// One image per asset, kept for the lifetime of the app — LUTs are
/// tiny (143 KB at 33³ RGBA) so a small map covers every bundled
/// LUT without pressuring the proxy cache.
class LutAssetCache {
  LutAssetCache._();

  static final LutAssetCache instance = LutAssetCache._();

  final Map<String, ui.Image> _cache = {};
  final Map<String, Future<ui.Image>> _loading = {};

  int get cachedCount => _cache.length;

  /// Cached image for [assetPath], or null. Cheap synchronous lookup.
  ui.Image? getCached(String assetPath) => _cache[assetPath];

  /// Load (or return the in-flight future for) [assetPath].
  Future<ui.Image> load(String assetPath) {
    final cached = _cache[assetPath];
    if (cached != null) return Future.value(cached);
    final pending = _loading[assetPath];
    if (pending != null) return pending;
    final fut = _decode(assetPath);
    _loading[assetPath] = fut;
    return fut;
  }

  Future<ui.Image> _decode(String assetPath) async {
    try {
      final data = await rootBundle.load(assetPath);
      final codec = await ui.instantiateImageCodec(
        data.buffer.asUint8List(),
      );
      final frame = await codec.getNextFrame();
      _cache[assetPath] = frame.image;
      _loading.remove(assetPath);
      _log.d('loaded', {'asset': assetPath});
      return frame.image;
    } catch (e, st) {
      _loading.remove(assetPath);
      _log.e('load failed',
          error: e, stackTrace: st, data: {'asset': assetPath});
      rethrow;
    }
  }

  /// Drop every cached image. Call on memory pressure; next access
  /// re-decodes from the bundle.
  void dispose() {
    for (final img in _cache.values) {
      img.dispose();
    }
    _cache.clear();
    _loading.clear();
  }
}
