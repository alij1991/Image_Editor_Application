import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import '../../../core/logging/app_logger.dart';
import '../../inference/rgb_ops.dart';
import '../bg_removal/bg_removal_strategy.dart';
import '../bg_removal/image_io.dart';

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
  });

  final BgRemovalStrategy removal;

  /// Strength of the Reinhard LAB transfer. 1.0 fully matches the
  /// new-bg palette — which can over-tint the subject on heavily
  /// coloured backgrounds. 0.8 is a natural default; expose via the
  /// picker later if users want finer control.
  final double colourTransferStrength;

  /// Run the full pipeline:
  ///   1. Extract subject alpha from [sourcePath] via [removal].
  ///   2. Decode + resize [backgroundPath] to the source's
  ///      dimensions.
  ///   3. Colour-transfer the subject toward the bg's LAB stats.
  ///   4. Alpha-composite subject over bg.
  ///
  /// Returns a new `ui.Image` sized to the source.
  Future<ui.Image> composeFromPaths({
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
    //    The mask doubles as the composite's alpha blend weight.
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

    // 5. Alpha composite subject over bg.
    final composite = Uint8List(w * h * 4);
    for (int p = 0; p < mask.length; p++) {
      final i = p * 4;
      final a = mask[p];
      final inv = 1.0 - a;
      composite[i] = (recoloured[i] * a + bgRgba[i] * inv).round().clamp(0, 255);
      composite[i + 1] =
          (recoloured[i + 1] * a + bgRgba[i + 1] * inv).round().clamp(0, 255);
      composite[i + 2] =
          (recoloured[i + 2] * a + bgRgba[i + 2] * inv).round().clamp(0, 255);
      composite[i + 3] = 255;
    }

    final image = await BgRemovalImageIo.encodeRgbaToUiImage(
      rgba: composite,
      width: w,
      height: h,
    );
    total.stop();
    _log.i('compose complete', {
      'ms': total.elapsedMilliseconds,
      'w': w,
      'h': h,
    });
    return image;
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
