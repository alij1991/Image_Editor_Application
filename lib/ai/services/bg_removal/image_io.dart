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
