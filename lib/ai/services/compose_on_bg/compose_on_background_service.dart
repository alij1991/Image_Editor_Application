import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import '../../../core/logging/app_logger.dart';
import '../../inference/rgb_ops.dart';
import '../bg_removal/bg_removal_strategy.dart';
import '../bg_removal/image_io.dart';
import 'compose_edge_ops.dart';

final _log = AppLogger('ComposeOnBgService');

/// Phase XV.3: composites a matte-extracted subject onto a new
/// background, running a Reinhard LAB colour transfer first so the
/// subject inherits the target scene's white point / hue cast.
///
/// The service uses:
///   - A pre-built [BgRemovalStrategy] for subject extraction (RVM
///     recommended — the cleanest hair / fur edges end-to-end).
///   - A background image path the user picks from the gallery.
///   - [RgbOps.reinhardLabTransfer] for colour match.
///
/// Ownership of the [removal] strategy is NOT transferred — the
/// caller is responsible for closing it (so a single RVM session
/// can drive multiple composes in a single UX flow if needed).
class ComposeOnBackgroundService {
  ComposeOnBackgroundService({
    required this.removal,
    this.colourTransferStrength = 0.8,
    this.alphaErodePasses = 1,
    this.alphaFeatherPasses = 0,
    this.decontaminationStrength = 0.9,
    this.contactShadowOpacity = 0.28,
  });

  final BgRemovalStrategy removal;

  /// Strength of the Reinhard LAB transfer. 1.0 fully matches the
  /// new-bg palette — which can over-tint the subject on heavily
  /// coloured backgrounds. 0.8 is a natural default; expose via the
  /// picker later if users want finer control.
  final double colourTransferStrength;

  /// Phase XVI.2 — how many 1-px morphological erosions to apply to
  /// the matte before feathering. One pass is enough to trim the
  /// outermost (contaminated) ring of pixels from the matting
  /// strategy's output. More than one shrinks the subject visibly.
  final int alphaErodePasses;

  /// Phase XVI.2/XVI.6 — number of separable 3-tap blur passes
  /// applied to the alpha channel after erosion. **Default 0
  /// (disabled) as of XVI.6**. Feathering widens the partial-alpha
  /// band, which exposes more of the matting network's uncertain
  /// edge pixels (especially RVM's fgr over-range values) to the
  /// final composite — the halo the XVI.2–XVI.5 chain chased.
  /// RVM's native matte softness is already good enough. Leave at
  /// 0 unless a strategy returns a hard binary mask that needs
  /// artificial softening.
  final int alphaFeatherPasses;

  /// Phase XVI.2/XVI.6 — interior-sampling colour decontamination
  /// strength. Raised from 0.75 to 0.9 in XVI.6 so partial-alpha
  /// edge pixels are pulled more aggressively toward the subject's
  /// interior colour, killing any residual fringe that the fgr
  /// clamp (XVI.6) + erosion didn't fully handle.
  final double decontaminationStrength;

  /// Phase XVI.2 — peak opacity of the contact shadow baked under
  /// the subject. 0 disables the shadow. Keep it subtle — 0.3 is
  /// the sweet spot for everyday lighting; stronger shadows only
  /// look right against very bright backgrounds.
  final double contactShadowOpacity;

  /// Phase XVI.6 diagnostic — when true, logs alpha histogram +
  /// partial-alpha pixel RGB samples at every stage of the edge
  /// op pipeline so we can see exactly where halos come from. Off
  /// in production; flip to true when investigating.
  static const bool _diag = true;

  /// Phase XVI.1: run the split compose pipeline.
  ///   1. Extract subject alpha from [sourcePath] via [removal].
  ///   2. Decode + cover-crop [backgroundPath] to the source's
  ///      dimensions.
  ///   3. Colour-transfer the subject toward the bg's LAB stats
  ///      (alpha-masked so only the subject pixels contribute to
  ///      statistics and get transformed).
  ///
  /// Returns a [ComposeResult] holding the two `ui.Image`s the
  /// editor should commit as two separate layers:
  ///   - [ComposeResult.background]: opaque new-bg raster.
  ///   - [ComposeResult.subject]: full-frame subject raster with
  ///     alpha. Draw this on top of the background.
  ///
  /// The caller owns both images and must dispose them after the
  /// layer cache has taken ownership.
  Future<ComposeResult> composeFromPaths({
    required String sourcePath,
    required String backgroundPath,
  }) async {
    final total = Stopwatch()..start();

    // 1. Matte the subject. The strategy returns a ui.Image with
    //    alpha-punched background pixels; extract its RGBA so we
    //    can operate per-pixel.
    final cutout = await removal.removeBackgroundFromPath(sourcePath);
    final byteData = await cutout.toByteData(
      format: ui.ImageByteFormat.rawStraightRgba,
    );
    if (byteData == null) {
      cutout.dispose();
      throw const ComposeOnBackgroundException(
        'Subject cutout returned no pixels',
      );
    }
    final subjectRgba = byteData.buffer.asUint8List();
    final w = cutout.width;
    final h = cutout.height;
    cutout.dispose();

    // 2. Load + resize background to the same dims. Done via
    //    `ui.instantiateImageCodec` with explicit target size so
    //    the result sits in source pixel space without extra
    //    Dart-side resampling.
    final bgRgba = await _decodeResized(backgroundPath, w, h);

    // 3. Build an alpha-driven mask for the colour transfer so only
    //    the matted subject pixels contribute to the source stats.
    final mask = Float32List(w * h);
    for (int p = 0; p < mask.length; p++) {
      mask[p] = subjectRgba[p * 4 + 3] / 255.0;
    }

    if (_diag) _logPixelStats('stage:matte', subjectRgba, w, h);

    // 4. Colour transfer. Reinhard preserves alpha, so the result
    //    is still a RGBA buffer with the matte's alpha intact —
    //    which is exactly what we want to ship as the subject layer.
    var recoloured = RgbOps.reinhardLabTransfer(
      source: subjectRgba,
      width: w,
      height: h,
      target: bgRgba,
      mask: mask,
      strength: colourTransferStrength,
    );

    if (_diag) _logPixelStats('stage:reinhard', recoloured, w, h);

    // 4a. Phase XVI.4 — reordered edge-quality pass. The XVI.2
    //     sequence (decontaminate → erode → feather → shadow) let
    //     the feather step resurrect alpha=0 pixels' original-bg
    //     RGB into the final composite as a bright halo (field
    //     report on 2026-04-22). The fix runs in this order:
    //
    //       1. Zero RGB where alpha=0 so any subsequent feather
    //          can't resurrect contaminated pixels.
    //       2. Erode (tighten the matte inward).
    //       3. Feather (soft ramp — now safe because bg RGB is 0).
    //       4. Decontaminate (AFTER feather, so the final
    //          partial-alpha band gets fresh interior-sampled RGB
    //          instead of the now-black zeroed pixels).
    //       5. Shadow (stamped last so it isn't blurred by feather).
    final needEdgeOps = alphaErodePasses > 0 ||
        alphaFeatherPasses > 0 ||
        decontaminationStrength > 0;
    if (needEdgeOps) {
      // Phase XVI.7 — aggressive wipe. Previously we only zeroed
      // α=0 pixels. The diagnostic log on 2026-04-22 showed the
      // halo was actually made of ~6500 pixels at α=1-63 carrying
      // RVM's foreground-estimate bright RGB — none of which my
      // threshold=1 wipe caught. Raise the threshold so every
      // partial-alpha pixel loses its contaminated RGB up-front;
      // the decontamination pass then refills them from interior.
      recoloured = ComposeEdgeOps.zeroRgbWhereTransparent(
        rgba: recoloured,
        width: w,
        height: h,
        threshold: 240,
      );
      if (_diag) _logPixelStats('stage:zero', recoloured, w, h);
    }
    if (alphaErodePasses > 0) {
      recoloured = ComposeEdgeOps.erodeAlpha(
        rgba: recoloured,
        width: w,
        height: h,
        iterations: alphaErodePasses,
      );
      if (_diag) _logPixelStats('stage:erode', recoloured, w, h);
    }
    if (alphaFeatherPasses > 0) {
      recoloured = ComposeEdgeOps.featherAlpha(
        rgba: recoloured,
        width: w,
        height: h,
        passes: alphaFeatherPasses,
      );
      if (_diag) _logPixelStats('stage:feather', recoloured, w, h);
    }
    if (decontaminationStrength > 0) {
      // Phase XVI.7 — widened decontamination range. `lo` drops
      // from 0.05 to 0.005 so even α=1-12 pixels (previously
      // skipped, leaving their zeroed black RGB to show as
      // faint darkening) are filled with interior RGB. `radius`
      // grows from 3 to 8 so the wider partial-alpha band
      // produced by upsampling + bilinear rendering is fully
      // covered — inner pixels can always find interior samples.
      recoloured = ComposeEdgeOps.decontaminateEdges(
        rgba: recoloured,
        width: w,
        height: h,
        strength: decontaminationStrength,
        lo: 0.005,
        radius: 8,
      );
      if (_diag) _logPixelStats('stage:decontam', recoloured, w, h);
    }
    if (contactShadowOpacity > 0) {
      recoloured = ComposeEdgeOps.stampContactShadow(
        rgba: recoloured,
        width: w,
        height: h,
        opacity: contactShadowOpacity,
      );
      if (_diag) _logPixelStats('stage:shadow', recoloured, w, h);
    }

    if (_diag) {
      _log.i('compose config', {
        'erode': alphaErodePasses,
        'feather': alphaFeatherPasses,
        'decontam': decontaminationStrength,
        'shadow': contactShadowOpacity,
        'reinhard': colourTransferStrength,
      });
    }

    // 5. Encode both rasters as ui.Images. No in-Dart composite —
    //    the editor stacks them as two layers and the painter
    //    composites at paint time so the user can still transform
    //    the subject.
    final background = await BgRemovalImageIo.encodeRgbaToUiImage(
      rgba: bgRgba,
      width: w,
      height: h,
    );
    final subject = await BgRemovalImageIo.encodeRgbaToUiImage(
      rgba: recoloured,
      width: w,
      height: h,
    );
    total.stop();
    _log.i('compose complete', {
      'ms': total.elapsedMilliseconds,
      'w': w,
      'h': h,
    });
    return ComposeResult(background: background, subject: subject);
  }

  Future<void> close() async {
    // Strategy lifetime is caller-owned — nothing to release here.
  }

  /// Phase XVI.6 — emit a condensed stats snapshot of [rgba] so the
  /// halo source can be traced through the pipeline. Logs:
  ///   - Alpha histogram (5 bins: 0 / 1-63 / 64-191 / 192-254 / 255).
  ///   - Partial-alpha RGB range (min / max / mean of R+G+B for
  ///     pixels where 0 < α < 255) — a bright halo shows up as a
  ///     mean partial-alpha brightness significantly above the
  ///     interior mean.
  ///   - Interior RGB range (mean of R+G+B for α = 255 pixels).
  ///   - Brightest partial-alpha sample's (α, R, G, B). If this
  ///     pins at near-white with a mid alpha, that's the halo in
  ///     numerical form.
  static void _logPixelStats(String stage, Uint8List rgba, int w, int h) {
    int a0 = 0, a1 = 0, a2 = 0, a3 = 0, a4 = 0;
    int partialCount = 0;
    int interiorCount = 0;
    int partialSum = 0, partialMin = 765, partialMax = 0;
    int interiorSum = 0;
    int brightestPartialSum = 0;
    int brightestA = 0, brightestR = 0, brightestG = 0, brightestB = 0;
    for (int i = 0; i < rgba.length; i += 4) {
      final a = rgba[i + 3];
      if (a == 0) {
        a0++;
      } else if (a < 64) {
        a1++;
      } else if (a < 192) {
        a2++;
      } else if (a < 255) {
        a3++;
      } else {
        a4++;
      }
      final brightness = rgba[i] + rgba[i + 1] + rgba[i + 2];
      if (a == 255) {
        interiorCount++;
        interiorSum += brightness;
      } else if (a > 0) {
        partialCount++;
        partialSum += brightness;
        if (brightness < partialMin) partialMin = brightness;
        if (brightness > partialMax) partialMax = brightness;
        if (brightness > brightestPartialSum) {
          brightestPartialSum = brightness;
          brightestA = a;
          brightestR = rgba[i];
          brightestG = rgba[i + 1];
          brightestB = rgba[i + 2];
        }
      }
    }
    final partialMean = partialCount > 0
        ? (partialSum / partialCount / 3).round()
        : -1;
    final interiorMean = interiorCount > 0
        ? (interiorSum / interiorCount / 3).round()
        : -1;
    final partialMinBr =
        partialCount > 0 ? (partialMin / 3).round() : -1;
    final partialMaxBr =
        partialCount > 0 ? (partialMax / 3).round() : -1;
    _log.i(stage, {
      'α=0': a0,
      'α<64': a1,
      'α<192': a2,
      'α<255': a3,
      'α=255': a4,
      'partialN': partialCount,
      'partialBr': '${partialMinBr}-${partialMaxBr} (mean=$partialMean)',
      'interiorBr': 'mean=$interiorMean',
      'brightestPartial':
          'α=$brightestA rgb=($brightestR,$brightestG,$brightestB)',
    });
  }

  Future<Uint8List> _decodeResized(
    String path,
    int targetW,
    int targetH,
  ) async {
    final bytes = await File(path).readAsBytes();
    // Probe the full-res dimensions so we can cover-crop (letterbox
    // would leave black bars on the composite). We instantiate
    // twice: once to read the full dims, then again at the cover
    // resolution so the codec does the heavy-lift resize in native.
    final probeCodec = await ui.instantiateImageCodec(bytes);
    final probeFrame = await probeCodec.getNextFrame();
    final fullW = probeFrame.image.width;
    final fullH = probeFrame.image.height;
    probeFrame.image.dispose();
    probeCodec.dispose();

    // Cover: scale so the shorter edge covers the target, then
    // centre-crop during the pixel read.
    final scale = math.max(targetW / fullW, targetH / fullH);
    final coverW = (fullW * scale).round();
    final coverH = (fullH * scale).round();
    final codec = await ui.instantiateImageCodec(
      bytes,
      targetWidth: coverW,
      targetHeight: coverH,
    );
    final frame = await codec.getNextFrame();
    codec.dispose();
    final img = frame.image;
    try {
      final bd = await img.toByteData(
        format: ui.ImageByteFormat.rawStraightRgba,
      );
      if (bd == null) {
        throw const ComposeOnBackgroundException(
          'Could not read background pixels',
        );
      }
      final coverRgba = bd.buffer.asUint8List();
      final offsetX = ((coverW - targetW) / 2).round().clamp(0, coverW - 1);
      final offsetY = ((coverH - targetH) / 2).round().clamp(0, coverH - 1);
      final out = Uint8List(targetW * targetH * 4);
      for (int y = 0; y < targetH; y++) {
        final srcY = y + offsetY;
        final srcRow = srcY * coverW;
        final dstRow = y * targetW;
        for (int x = 0; x < targetW; x++) {
          final srcX = x + offsetX;
          final srcIdx = (srcRow + srcX) * 4;
          final dstIdx = (dstRow + x) * 4;
          out[dstIdx] = coverRgba[srcIdx];
          out[dstIdx + 1] = coverRgba[srcIdx + 1];
          out[dstIdx + 2] = coverRgba[srcIdx + 2];
          out[dstIdx + 3] = coverRgba[srcIdx + 3];
        }
      }
      return out;
    } finally {
      img.dispose();
    }
  }
}

/// Two-image output of [ComposeOnBackgroundService.composeFromPaths].
/// Both images are the same pixel dimensions as the source. The
/// editor commits them as two layers: background first (full-frame,
/// opaque), subject on top (full-frame, alpha, transformable).
class ComposeResult {
  const ComposeResult({required this.background, required this.subject});

  /// Full-frame opaque new-bg raster, already cover-cropped to the
  /// source dimensions.
  final ui.Image background;

  /// Full-frame matted subject raster with alpha. RGB has the
  /// Reinhard colour transfer applied; alpha is the matting
  /// strategy's output. Draw with transform honoured so the user
  /// can move / scale / rotate it.
  final ui.Image subject;
}

class ComposeOnBackgroundException implements Exception {
  const ComposeOnBackgroundException(this.message, {this.cause});
  final String message;
  final Object? cause;

  @override
  String toString() {
    if (cause == null) return 'ComposeOnBackgroundException: $message';
    return 'ComposeOnBackgroundException: $message (caused by $cause)';
  }
}
