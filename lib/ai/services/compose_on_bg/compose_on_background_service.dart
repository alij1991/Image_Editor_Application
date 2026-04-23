import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import '../../../core/logging/app_logger.dart';
import '../../inference/rgb_ops.dart';
import '../bg_removal/bg_removal_strategy.dart';
import '../bg_removal/image_io.dart';
import 'compose_edge_refine.dart';

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

    // 5. Keep the straight-alpha, colour-transferred subject as
    //    the RAW that [ComposeEdgeRefine] re-bakes from whenever
    //    the user slides the feather / decontam sliders. Stored in
    //    [ComposeResult.subjectRawRgba]; not touched further here.
    final rawSubjectRgba = Uint8List.fromList(recoloured);

    // 6. Phase XVI.12 halo fix — premultiply RGB by α before
    //    encoding the subject. See [ComposeEdgeRefine._premultiply]
    //    for the math (same step, factored into the refine service
    //    so the re-bake path shares the identical code). At zero
    //    refine strength this matches the pre-XVI.15 output bit-
    //    for-bit.
    final baked = ComposeEdgeRefine.apply(
      straightRgba: rawSubjectRgba,
      width: w,
      height: h,
      featherPx: 0.0,
      decontamStrength: 0.0,
    );

    // 7. Encode both rasters as ui.Images.
    final background = await BgRemovalImageIo.encodeRgbaToUiImage(
      rgba: bgRgba,
      width: w,
      height: h,
    );
    final subject = await BgRemovalImageIo.encodeRgbaToUiImage(
      rgba: baked,
      width: w,
      height: h,
    );
    total.stop();
    _log.i('compose complete', {
      'ms': total.elapsedMilliseconds,
      'w': w,
      'h': h,
    });
    return ComposeResult(
      background: background,
      subject: subject,
      subjectRawRgba: rawSubjectRgba,
      width: w,
      height: h,
    );
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
///
/// Phase XVI.15 adds the subject's straight-alpha RGBA bytes so the
/// session can rebake the subject with different edge-refine
/// parameters without re-running bg-removal. The [subject] ui.Image
/// was encoded from `ComposeEdgeRefine.apply(subjectRawRgba, ...)`
/// at zero refine strength — it is the "default bake" the user
/// starts from.
class ComposeResult {
  const ComposeResult({
    required this.background,
    required this.subject,
    required this.subjectRawRgba,
    required this.width,
    required this.height,
  });

  final ui.Image background;
  final ui.Image subject;

  /// Pre-premultiply, pre-feather, colour-transferred subject
  /// pixels. Used by the session to re-invoke
  /// [ComposeEdgeRefine.apply] when the user moves an edge-refine
  /// slider. `width * height * 4` bytes long.
  final Uint8List subjectRawRgba;

  final int width;
  final int height;
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
