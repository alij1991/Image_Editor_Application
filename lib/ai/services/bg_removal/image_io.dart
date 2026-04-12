import 'dart:io';
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

  /// Decode a file on disk into a raw RGBA8 buffer plus dimensions.
  ///
  /// The returned `ui.Image` is disposed internally after the bytes
  /// are copied out, so the caller only has to dispose the final
  /// cutout image.
  static Future<DecodedRgba> decodeFileToRgba(String path) async {
    final bytes = await File(path).readAsBytes();
    final codec = await ui.instantiateImageCodec(bytes);
    final frame = await codec.getNextFrame();
    codec.dispose();
    final image = frame.image;
    try {
      final bd = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
      if (bd == null) {
        throw const BgRemovalIoException('Failed to read source pixels');
      }
      return DecodedRgba(
        bytes: bd.buffer.asUint8List(),
        width: image.width,
        height: image.height,
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
    final completer = <ui.Image>[];
    ui.decodeImageFromPixels(
      rgba,
      width,
      height,
      ui.PixelFormat.rgba8888,
      completer.add,
    );
    while (completer.isEmpty) {
      await Future<void>.delayed(Duration.zero);
    }
    return completer.first;
  }
}

/// Result of [BgRemovalImageIo.decodeFileToRgba].
class DecodedRgba {
  const DecodedRgba({
    required this.bytes,
    required this.width,
    required this.height,
  });

  final Uint8List bytes;
  final int width;
  final int height;
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
