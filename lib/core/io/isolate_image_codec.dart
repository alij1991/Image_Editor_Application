import 'dart:isolate';
import 'dart:typed_data';

import 'package:image/image.dart' as img;

/// XVI.125 (D4) — off-UI-isolate image encoding.
///
/// The `image` package's encoders (`encodeJpg` / `encodePng`) are
/// pure-Dart and CPU-heavy: a 12 MP / 4K frame takes ~0.5–2 s, which
/// blocks the UI thread (ANR / dropped frames) if run inline. These
/// helpers run the codec on a short-lived worker isolate via
/// [Isolate.run], mirroring the scanner's `image_processor.dart` pattern.
///
/// `dart:ui` handles (ui.Image) CANNOT cross the isolate boundary, so the
/// caller must hand over raw RGBA bytes (e.g. from
/// `ui.Image.toByteData(format: rawRgba)` on the UI thread). Plain
/// `Uint8List` + primitives copy across cleanly.

/// Output container format for [encodeRgbaInIsolate].
enum IsolateImageFormat { jpeg, png }

class _EncodeRgbaPayload {
  const _EncodeRgbaPayload({
    required this.rgba,
    required this.width,
    required this.height,
    required this.format,
    required this.quality,
  });

  final Uint8List rgba;
  final int width;
  final int height;
  final IsolateImageFormat format;
  final int quality;
}

/// Encode raw RGBA8888 [rgba] (length must be `width*height*4`) to JPEG or
/// PNG on a worker isolate. [quality] (1–100) applies to JPEG only.
Future<Uint8List> encodeRgbaInIsolate({
  required Uint8List rgba,
  required int width,
  required int height,
  required IsolateImageFormat format,
  int quality = 90,
}) {
  return Isolate.run(
    () => _encodeRgba(
      _EncodeRgbaPayload(
        rgba: rgba,
        width: width,
        height: height,
        format: format,
        quality: quality,
      ),
    ),
  );
}

/// Top-level so it can run inside [Isolate.run] (no captured `this`).
Uint8List _encodeRgba(_EncodeRgbaPayload p) {
  final rgba = p.rgba;
  // img.Image.fromBytes reads the ByteBuffer from offset 0, so a view
  // with a non-zero offset (or shorter than its backing buffer) would
  // encode the WRONG pixels. Normalise to an offset-0 buffer first;
  // the common full-buffer case is zero-copy.
  final normalized = (rgba.offsetInBytes == 0 &&
          rgba.lengthInBytes == rgba.buffer.lengthInBytes)
      ? rgba
      : Uint8List.fromList(rgba);
  final image = img.Image.fromBytes(
    width: p.width,
    height: p.height,
    bytes: normalized.buffer,
    numChannels: 4,
    order: img.ChannelOrder.rgba,
  );
  switch (p.format) {
    case IsolateImageFormat.jpeg:
      return img.encodeJpg(image, quality: p.quality);
    case IsolateImageFormat.png:
      return img.encodePng(image);
  }
}
