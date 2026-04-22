import 'dart:async';
import 'dart:collection';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:crypto/crypto.dart' show sha256;
import 'package:flutter/foundation.dart' show visibleForTesting;

import '../../../core/logging/app_logger.dart';
import '../../../engine/pipeline/edit_op_type.dart';
import '../../../engine/pipeline/edit_pipeline.dart';
import '../../../engine/pipeline/matrix_composer.dart';
import '../../../engine/presets/preset.dart';

final _log = AppLogger('PresetThumbs');

/// Derived visual characterisation of a preset as applied to the
/// current photo. Held by the preset strip so each tile can render a
/// real preview of what the preset does instead of a hashed gradient.
///
/// We intentionally keep this cheap — we approximate each preset by
/// folding its matrix-composable ops (exposure, contrast, saturation,
/// hue, brightness) plus a linear-RGB approximation of temperature
/// and tint into a single 5×4 color matrix. Flutter can then render
/// the user's source image through that matrix via
/// `ColorFiltered(ColorFilter.matrix(...))`, which is one compositor
/// pass on any modern device.
///
/// What we **don't** approximate at thumbnail scale:
///   - vignette (rendered as a separate `RadialGradient` overlay)
///   - grain, clarity, dehaze, highlights/shadows/whites/blacks,
///     vibrance, split-toning
///
/// These effects require dedicated shader passes that don't fold into
/// a matrix. Re-rendering each tile through the full shader chain
/// would give pixel-accurate thumbnails but costs 3–5 FBOs per preset
/// per source change, which is wasteful for a preview strip. The
/// approximation below captures the *dominant* colour character of
/// every preset in the built-in set (B&W / warm / cool / faded /
/// saturated) — which is what users actually scan the strip for.
class PresetThumbnailRecipe {
  const PresetThumbnailRecipe({
    required this.colorMatrix,
    required this.vignetteAmount,
  });

  /// 20-element row-major 5×4 matrix to pass to
  /// `ColorFilter.matrix(...)`. Never null — always a well-formed
  /// matrix (identity for the Original preset).
  final Float32List colorMatrix;

  /// 0.0 – 1.0 strength of the vignette overlay. 0 = no vignette.
  final double vignetteAmount;

  bool get hasVignette => vignetteAmount > 0.02;
}

/// Compiles preset definitions into cheap-to-render
/// [PresetThumbnailRecipe]s and caches them keyed by the **preview
/// hash** + preset id.
///
/// ## Phase VI.6 — preview-hash keying
///
/// The previous cache (`preset.id → recipe`) was per-session and
/// required a manual `bumpGeneration()` call whenever the source
/// image changed. That has two problems:
///
/// 1. **Re-opening the same photo rebuilds every recipe** — the cache
///    dies with the session. 25 matrix composes × ~2 per-recipe
///    Float32List(20) allocations = wasteful churn for identical work.
/// 2. **Stale-cache footgun** — any new code path that swaps the
///    source image has to remember to call `bumpGeneration`, and
///    forgetting makes the strip show thumbnails that don't match the
///    photo on screen.
///
/// Preview-hash keying fixes both: the cache lives at module scope
/// (survives across sessions) and entries are tagged with a content
/// hash of the source proxy's bytes. A different photo → a different
/// hash → a cache miss (safely). The same photo reopened → the same
/// hash → an instant cache hit. Invalidation is implicit in the key;
/// there's no "remember to bump" discipline for future callers.
///
/// ## Scope
///
/// - Recipes today are a pure function of the preset's `operations`;
///   the preview hash is included so that (a) the cache is naturally
///   content-keyed, and (b) future callers that DO derive pixel-level
///   data from the source (a proper GPU-rendered thumbnail path) can
///   slot into the same key discipline without a new cache layer.
/// - Bounded by a small LRU (64 entries) so a power user cycling
///   through many photos doesn't hoard memory — 64 × (20 floats + a
///   double) ≈ 5.5 KB, trivial.
/// - Disposal: recipes hold no native handles, so eviction is GC-only.
class PresetThumbnailCache {
  PresetThumbnailCache._();

  /// Process-wide singleton. Module-level cache is keyed by
  /// (previewHash, preset.id); there's no session state that the
  /// cache could leak between users.
  static final PresetThumbnailCache instance = PresetThumbnailCache._();

  /// Max number of (previewHash, preset.id) entries to keep alive.
  /// 64 covers ~2 photos' worth of the full built-in strip (25
  /// presets per photo + custom presets). Empirically tiny (~5.5 KB
  /// across all entries) so the bound is belt-and-suspenders, not a
  /// real memory pressure valve.
  static const int _capacity = 64;

  /// LinkedHashMap preserves insertion order so move-to-MRU on hit is
  /// a remove + re-insert. Insertion order == lowest iteration order;
  /// `keys.first` is the oldest (LRU-victim).
  final LinkedHashMap<_RecipeKey, PresetThumbnailRecipe> _entries =
      LinkedHashMap<_RecipeKey, PresetThumbnailRecipe>();

  int _hits = 0;
  int _misses = 0;
  int _builds = 0;

  /// Return the render recipe for [preset] applied to the preview
  /// image whose content hashes to [previewHash]. Cached per
  /// (previewHash, preset.id); subsequent calls with the same key
  /// are O(1). On miss, builds, promotes the entry to MRU, and
  /// returns.
  ///
  /// [previewHash] comes from [hashPreviewImage] — callers should
  /// compute it once when the proxy lands and reuse the result for
  /// every tile render.
  PresetThumbnailRecipe recipeFor(Preset preset, String previewHash) {
    final key = _RecipeKey(previewHash, preset.id);
    final existing = _entries.remove(key);
    if (existing != null) {
      _entries[key] = existing; // promote to MRU
      _hits++;
      return existing;
    }
    _misses++;
    final built = _build(preset);
    _builds++;
    if (_entries.length >= _capacity) {
      // Evict LRU (oldest insertion).
      _entries.remove(_entries.keys.first);
    }
    _entries[key] = built;
    return built;
  }

  PresetThumbnailRecipe _build(Preset preset) {
    // Build an EditPipeline fragment so MatrixComposer can fold the
    // matrix-composable ops for us (exposure, contrast, saturation,
    // hue, brightness, channelMixer). Non-matrix ops are skipped here
    // and handled by the supplementary logic below.
    var pipeline = EditPipeline.forOriginal('__thumb__');
    for (final op in preset.operations) {
      if (op.isMatrixComposable) {
        pipeline = pipeline.append(op);
      }
    }
    const composer = MatrixComposer();
    var matrix = composer.compose(pipeline);

    // Temperature / tint — approximate as linear RGB channel multipliers
    // on top of the composed matrix. Values roughly match what the
    // `color_grading.frag` shader does for small deltas (we're only
    // showing a 128 px preview so perfect parity isn't needed).
    double temp = 0, tint = 0;
    double vignetteAmount = 0;
    for (final op in preset.operations) {
      switch (op.type) {
        case EditOpType.temperature:
          temp += op.doubleParam('value');
          break;
        case EditOpType.tint:
          tint += op.doubleParam('value');
          break;
        case EditOpType.vignette:
          vignetteAmount =
              op.doubleParam('amount').clamp(0.0, 1.0).toDouble();
          break;
      }
    }
    if (temp != 0 || tint != 0) {
      matrix = _composeScaling(
        matrix: matrix,
        // Warm (+temp) boosts R, cuts B; cool does the inverse. The
        // 0.35 scale factor keeps the effect perceptually close to the
        // full shader at thumbnail size.
        rScale: 1 + temp * 0.35,
        gScale: 1 + tint * 0.20,
        bScale: 1 - temp * 0.35 - tint * 0.20,
      );
    }

    return PresetThumbnailRecipe(
      colorMatrix: matrix,
      vignetteAmount: vignetteAmount,
    );
  }

  /// Post-multiply the 5×4 [matrix] by an RGB channel-scaling matrix.
  /// Used to fold temperature/tint into the composer output without
  /// going through the full MatrixComposer machinery (which would
  /// require fabricating fake EditOperations for a non-matrix type).
  Float32List _composeScaling({
    required Float32List matrix,
    required double rScale,
    required double gScale,
    required double bScale,
  }) {
    final scaling = Float32List(20);
    scaling[0] = rScale;
    scaling[6] = gScale;
    scaling[12] = bScale;
    scaling[18] = 1.0;
    return MatrixComposer.multiply(scaling, matrix);
  }

  @visibleForTesting
  int get debugHits => _hits;

  @visibleForTesting
  int get debugMisses => _misses;

  @visibleForTesting
  int get debugBuilds => _builds;

  @visibleForTesting
  int get debugSize => _entries.length;

  /// Drop every cached entry + zero counters. Test hook (tests share
  /// the process-wide singleton, so per-test isolation requires a
  /// reset). Not intended for production use — preview-hash keying
  /// makes explicit invalidation unnecessary.
  @visibleForTesting
  void debugReset() {
    _entries.clear();
    _hits = 0;
    _misses = 0;
    _builds = 0;
  }
}

/// Cache lookup key — records are `==`/`hashCode` correct so they
/// slot into the LinkedHashMap without a stringly-typed intermediate.
class _RecipeKey {
  const _RecipeKey(this.previewHash, this.presetId);
  final String previewHash;
  final String presetId;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is _RecipeKey &&
          previewHash == other.previewHash &&
          presetId == other.presetId);

  @override
  int get hashCode => Object.hash(previewHash, presetId);
}

/// Produce a stable short hash that identifies the proxy's content.
///
/// The preset strip only needs the hash to distinguish "is this the
/// same photo I thumbnailed last time?" — different hashes must not
/// collide for visually-different photos, but the absolute value of
/// the hash doesn't matter. We read the proxy's raw RGBA once and
/// feed it to SHA-256; the resulting 64-char hex string goes into
/// the cache key.
///
/// The proxy is capped at 128 px long-edge upstream (see
/// [buildThumbnailProxy]), so the hash input is at most
/// 128 × 128 × 4 = 65 KB. SHA-256 on 65 KB is on the order of 200 μs
/// on a mid-range phone — measured once per session, amortised over
/// 25+ cache lookups. Returning null means we couldn't read the
/// image; callers fall back to treating every thumbnail as a fresh
/// request.
Future<String?> hashPreviewImage(ui.Image proxy) async {
  final bytes = await proxy.toByteData(format: ui.ImageByteFormat.rawRgba);
  if (bytes == null) {
    _log.w('hashPreviewImage: toByteData returned null');
    return null;
  }
  final digest = sha256.convert(bytes.buffer.asUint8List());
  return digest.toString();
}

/// Scale [source] to a 128 px long-edge [ui.Image]. Call once per
/// source change and share the result across every tile. The caller
/// owns the returned image and must `dispose()` it when finished.
Future<ui.Image> buildThumbnailProxy(ui.Image source) async {
  const targetLongEdge = 128;
  final w = source.width;
  final h = source.height;
  final longEdge = w > h ? w : h;
  if (longEdge <= targetLongEdge) {
    // Already small enough — clone via toByteData so the caller can
    // own the result and dispose independently of the caller's source.
    return _cloneImage(source);
  }
  final scale = targetLongEdge / longEdge;
  final outW = (w * scale).round();
  final outH = (h * scale).round();
  final recorder = ui.PictureRecorder();
  final canvas = ui.Canvas(recorder);
  final src = ui.Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble());
  final dst = ui.Rect.fromLTWH(0, 0, outW.toDouble(), outH.toDouble());
  final paint = ui.Paint()..filterQuality = ui.FilterQuality.medium;
  canvas.drawImageRect(source, src, dst, paint);
  final picture = recorder.endRecording();
  final img = await picture.toImage(outW, outH);
  picture.dispose();
  return img;
}

Future<ui.Image> _cloneImage(ui.Image source) async {
  final bytes = await source.toByteData(format: ui.ImageByteFormat.rawRgba);
  if (bytes == null) return source;
  final completer = Completer<ui.Image>();
  ui.decodeImageFromPixels(
    bytes.buffer.asUint8List(),
    source.width,
    source.height,
    ui.PixelFormat.rgba8888,
    completer.complete,
  );
  return completer.future;
}
