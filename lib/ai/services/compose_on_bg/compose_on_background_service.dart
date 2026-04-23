import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import '../../../core/logging/app_logger.dart';
import '../../inference/rgb_ops.dart';
import '../bg_removal/bg_removal_strategy.dart';
import '../bg_removal/image_io.dart';

final _log = AppLogger('ComposeOnBgService');

/// Phase XV.3 + XVI.11: composite a matted subject onto a new
/// background, with Reinhard LAB colour transfer and a split-layer
/// output so the subject can be moved / scaled / rotated after the
/// fact.
///
/// The service does not do the alpha composite itself — Flutter
/// renders the two images as a layer stack, which is how the
/// transform-aware subject survives redraws. The catch (learned
/// the hard way in Phase XVI.1–XVI.10): Flutter's bilinear
/// filtering samples across the matte edge and can pick up the
/// ORIGINAL photo's bg colour that matting strategies leave in the
/// RGB channels wherever α=0. That shows up as a bright halo
/// against contrasting new backgrounds.
///
/// The XVI.11 mitigation is narrow and surgical: zero the RGB on
/// every subject pixel whose α is below [lowAlphaZeroThreshold].
/// Those pixels contribute nothing to a clean alpha-over blend
/// anyway (α < ~12 % means < 5 % of the pixel's RGB reaches the
/// output), but Flutter's bilinear filter CAN'T spread bright
/// contamination from them into the filtered edge if their RGB is
/// zero. The matte's natural soft edge (α above the threshold) is
/// preserved unchanged so hair still looks soft and non-aliased.
///
/// Ownership of the [removal] strategy is NOT transferred — the
/// caller is responsible for closing it.
class ComposeOnBackgroundService {
  ComposeOnBackgroundService({
    required this.removal,
    this.colourTransferStrength = 0.8,
  });

  final BgRemovalStrategy removal;

  /// Strength of the Reinhard LAB transfer. 1.0 fully matches the
  /// new-bg palette — which can over-tint the subject on heavily
  /// coloured backgrounds. 0.8 is a natural default.
  final double colourTransferStrength;

  /// Run the pipeline and return [ComposeResult].
  ///   1. Extract subject alpha from [sourcePath] via [removal].
  ///   2. Decode + cover-crop [backgroundPath] to the source's
  ///      dimensions.
  ///   3. Colour-transfer the subject toward the bg's LAB stats.
  ///   4. Zero low-α RGB (XVI.11 halo fix).
  ///   5. Encode both images and return.
  Future<ComposeResult> composeFromPaths({
    required String sourcePath,
    required String backgroundPath,
  }) async {
    final total = Stopwatch()..start();

    // 1. Matte the subject.
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

    // 2. Load + cover-crop the new bg to the source dims.
    final bgRgba = await _decodeResized(backgroundPath, w, h);

    // 3. Mask = subject's alpha, used for Reinhard stats gating.
    final mask = Float32List(w * h);
    for (int p = 0; p < mask.length; p++) {
      mask[p] = subjectRgba[p * 4 + 3] / 255.0;
    }

    // 4. Colour transfer.
    final recoloured = RgbOps.reinhardLabTransfer(
      source: subjectRgba,
      width: w,
      height: h,
      target: bgRgba,
      mask: mask,
      strength: colourTransferStrength,
    );

    // 5. Phase XVI.12 halo fix — premultiply RGB by α before
    //    encoding the subject.
    //
    // Why: Flutter's `drawImageRect` with `FilterQuality.medium`
    // bilinear-samples the image BEFORE applying alpha-over. For
    // straight-alpha RGBA, bilinear computes
    //   avg_rgb = Σ rgb_i / N
    //   avg_α  = Σ α_i  / N
    // and composites as `avg_rgb * avg_α + bg * (1-avg_α)`. That's
    // mathematically wrong for alpha compositing — at the matte
    // boundary, the "outside" pixels (α=0, but RGB = original bg
    // from the source photo) leak their bright RGB into the
    // filtered sample because `avg_rgb` averages them equally with
    // the interior. The correct alpha-aware formula weights rgb by
    // its own α: `avg_premul_rgb = Σ(rgb_i*α_i) / N`. That's what
    // pre-multiplying gets us.
    //
    // Flutter's `PixelFormat.rgba8888` is nominally straight, so
    // passing premultiplied values means Flutter internally
    // multiplies by α a second time, giving an effective α² curve.
    // Net effect: edge pixels fade to transparent a bit sharper
    // than they would on "pretty math", which visually reads as
    // slightly tighter matte edges — and crucially, the bilinear
    // filter can't resurrect bright contamination as a halo
    // because every zero-α pixel has exactly zero RGB by
    // construction.
    for (int i = 0; i < recoloured.length; i += 4) {
      final a = recoloured[i + 3];
      if (a == 0) {
        recoloured[i] = 0;
        recoloured[i + 1] = 0;
        recoloured[i + 2] = 0;
      } else if (a < 255) {
        recoloured[i] = (recoloured[i] * a) ~/ 255;
        recoloured[i + 1] = (recoloured[i + 1] * a) ~/ 255;
        recoloured[i + 2] = (recoloured[i + 2] * a) ~/ 255;
      }
      // α=255 pixels: rgb * 255 / 255 = rgb (no change).
    }

    // 6. Encode both rasters as ui.Images.
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

  Future<Uint8List> _decodeResized(
    String path,
    int targetW,
    int targetH,
  ) async {
    final bytes = await File(path).readAsBytes();
    final probeCodec = await ui.instantiateImageCodec(bytes);
    final probeFrame = await probeCodec.getNextFrame();
    final fullW = probeFrame.image.width;
    final fullH = probeFrame.image.height;
    probeFrame.image.dispose();
    probeCodec.dispose();

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

/// Two-image output: the opaque new-bg raster + the matted subject
/// raster. The editor commits them as two layers; the subject is
/// transformable, the background is fixed.
class ComposeResult {
  const ComposeResult({required this.background, required this.subject});

  final ui.Image background;
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
