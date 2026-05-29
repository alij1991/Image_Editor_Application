import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

/// Small helpers shared between the download-backed background-removal
/// strategies (MODNet, RMBG, U²-Net) for turning file paths into raw
/// RGBA buffers and back.
///
/// Kept in one place so every strategy can skip the `dart:ui` codec
/// dance directly and focus on its own tensor logic.
class BgRemovalImageIo {
  const BgRemovalImageIo._();

  /// Maximum edge length for decoded images. Images larger than this
  /// are downscaled during decoding to avoid OOM on high-resolution
  /// photos (e.g. 24 MP camera images). The model input is typically
  /// 1024×1024 so anything above this is wasted memory. Kept at 1024
  /// to minimize peak memory alongside the ~44 MB ONNX model.
  static const int maxDecodeDimension = 1024;

  /// Decode dimension targeted by portrait-beauty / sky-replace
  /// services. Preview canvases on typical mobile devices top out
  /// around 1920 px; decoding at 2048 keeps the layer bigger than
  /// the preview so the layer painter never has to upscale (which
  /// adds visible softness on top of the intentional effect). The
  /// 2 048 × 1 536 RGBA buffer is ~12 MB, well under budget.
  static const int previewQualityDecodeDimension = 2048;

  /// Phase XVI.66c.fix — full-resolution decode tier for the
  /// compose-on-bg subject cutout. Used by [RmbgBgRemoval] and
  /// (eventually) the other matting strategies to preserve
  /// pinch-zoom-grade detail in the subject's INTERIOR RGB pixels.
  ///
  /// The matting model still runs at its native ~1024 input — the
  /// 1024² alpha mask is bilinear-upsampled back to this dimension
  /// when blended into the source RGB. The RGB interior (α=1
  /// region) therefore inherits the original photo's pixels at
  /// native sampling, which is what the eye actually reads as
  /// "subject quality". The matte transition band stays capped at
  /// the model's training resolution.
  ///
  /// Capped at 4096 — handles all current iPhone main-camera
  /// outputs at native res (24 MP = 6048×4032 → halved to 4096×
  /// 2731 to fit; 12 MP = 4032×3024 → unchanged). A 4096 × 2731
  /// RGBA buffer is ~45 MB, which is the upper end of "safe" for
  /// a transient compose call on mid-range mobile devices.
  static const int nativeQualityDecodeDimension = 4096;

  /// XVI.104 — policy alias: the decode tier every AI service that
  /// returns a FULL-FRAME `ui.Image` (one that becomes an editor
  /// layer/cutout composited onto the canvas at source resolution)
  /// MUST use.
  ///
  /// If such a service decodes below the source resolution, the
  /// layer painter / shader renderer bilinear-UPSCALES the low-res
  /// cutout onto the canvas (and onto the full-res export) → visible
  /// blur. This was the XVI.103 denoise/deblur regression; the
  /// XVI.104 audit found the same shape in MODNet, RVM, face
  /// restore, and hair/clothes recolour. The model still runs at
  /// its own (≤1024) input — only the decode + final encode + blend
  /// happen at this resolution, so inference cost is unchanged.
  ///
  /// Aliases [nativeQualityDecodeDimension] so the policy is named
  /// at the call sites and a single regression test pins it.
  static const int fullFrameDecodeDimension = nativeQualityDecodeDimension;

  /// Decode a file on disk into a raw RGBA8 buffer plus dimensions.
  ///
  /// Images larger than [maxDecodeDimension] on either edge are
  /// downscaled during codec decoding (hardware-accelerated, much
  /// cheaper than full-res decode + manual resize).
  ///
  /// The returned `ui.Image` is disposed internally after the bytes
  /// are copied out, so the caller only has to dispose the final
  /// cutout image.
  static Future<DecodedRgba> decodeFileToRgba(
    String path, {
    int maxDimension = maxDecodeDimension,
  }) async {
    final bytes = await File(path).readAsBytes();

    // Peek at the full-size image to decide if we need to downscale.
    final fullCodec = await ui.instantiateImageCodec(bytes);
    final probeFrame = await fullCodec.getNextFrame();
    final fullW = probeFrame.image.width;
    final fullH = probeFrame.image.height;
    probeFrame.image.dispose();
    fullCodec.dispose();

    int? targetW;
    int? targetH;
    final longest = math.max(fullW, fullH);
    if (longest > maxDimension) {
      final scale = maxDimension / longest;
      targetW = (fullW * scale).round();
      targetH = (fullH * scale).round();
    }

    final codec = await ui.instantiateImageCodec(
      bytes,
      targetWidth: targetW,
      targetHeight: targetH,
    );
    final frame = await codec.getNextFrame();
    codec.dispose();
    final image = frame.image;
    try {
      final bd = await image.toByteData(
        format: ui.ImageByteFormat.rawStraightRgba,
      );
      if (bd == null) {
        throw const BgRemovalIoException('Failed to read source pixels');
      }
      return DecodedRgba(
        bytes: bd.buffer.asUint8List(),
        width: image.width,
        height: image.height,
        originalWidth: fullW,
        originalHeight: fullH,
      );
    } finally {
      image.dispose();
    }
  }

  /// Upload an RGBA buffer back into a new `ui.Image`. Convenience
  /// wrapper around `decodeImageFromPixels` that converts its
  /// callback-based API to a `Future`.
  static Future<ui.Image> encodeRgbaToUiImage({
    required Uint8List rgba,
    required int width,
    required int height,
  }) async {
    final completer = Completer<ui.Image>();
    ui.decodeImageFromPixels(
      rgba,
      width,
      height,
      ui.PixelFormat.rgba8888,
      completer.complete,
    );
    return completer.future;
  }
}

/// Result of [BgRemovalImageIo.decodeFileToRgba].
class DecodedRgba {
  const DecodedRgba({
    required this.bytes,
    required this.width,
    required this.height,
    required this.originalWidth,
    required this.originalHeight,
  });

  final Uint8List bytes;
  final int width;
  final int height;

  /// Dimensions of the file on disk before any downscaling. Used by
  /// portrait-beauty services to compute the coordinate-space ratio
  /// between the face-detection decode (max 1536 px) and the service
  /// decode (max 1024 px) so face coordinates can be scaled correctly.
  final int originalWidth;
  final int originalHeight;
}

/// Typed exception for image IO failures inside the bg-removal
/// services. Kept separate from [BgRemovalException] so callers can
/// distinguish "image codec failed" from "model inference failed".
class BgRemovalIoException implements Exception {
  const BgRemovalIoException(this.message);
  final String message;

  @override
  String toString() => 'BgRemovalIoException: $message';
}
