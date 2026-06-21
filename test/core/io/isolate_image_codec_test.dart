import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

import 'package:image_editor/core/io/isolate_image_codec.dart';

/// XVI.125 (D4) — the off-UI-isolate codec helpers. These run real
/// `Isolate.run` work in the test VM and assert the container magic
/// bytes, so a regression in the payload marshalling or codec wiring is
/// caught.
Uint8List _solidRgba(int w, int h) {
  final out = Uint8List(w * h * 4);
  for (var i = 0; i < out.length; i += 4) {
    out[i] = 200; // R
    out[i + 1] = 100; // G
    out[i + 2] = 50; // B
    out[i + 3] = 255; // A
  }
  return out;
}

void main() {
  group('encodeRgbaInIsolate', () {
    test('produces a valid JPEG (SOI marker) off the main isolate',
        () async {
      final bytes = await encodeRgbaInIsolate(
        rgba: _solidRgba(8, 8),
        width: 8,
        height: 8,
        format: IsolateImageFormat.jpeg,
        quality: 85,
      );
      expect(bytes.length, greaterThan(2));
      expect(bytes[0], 0xFF); // JPEG SOI
      expect(bytes[1], 0xD8);
    });

    test('produces a valid PNG (8-byte signature)', () async {
      final bytes = await encodeRgbaInIsolate(
        rgba: _solidRgba(8, 8),
        width: 8,
        height: 8,
        format: IsolateImageFormat.png,
      );
      const sig = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A];
      expect(bytes.sublist(0, 8), sig);
    });

    test('honours a non-zero-offset view (encodes the right pixels)',
        () async {
      // A 2×2 RED image stored as a VIEW at offset 8 of a buffer whose
      // head is junk (99s). If the encoder read from buffer offset 0 (the
      // pre-fix bug) it would encode junk; honouring the view encodes red.
      // Pass the RAW view (not a copy) so this genuinely guards offset
      // handling across the isolate, then decode + assert the pixel.
      const w = 2, h = 2;
      final backing = Uint8List(8 + w * h * 4)..fillRange(0, 8, 99);
      final view = Uint8List.view(backing.buffer, 8, w * h * 4);
      for (var i = 0; i < view.length; i += 4) {
        view[i] = 255; // R
        view[i + 1] = 0; // G
        view[i + 2] = 0; // B
        view[i + 3] = 255; // A
      }
      final png = await encodeRgbaInIsolate(
        rgba: view,
        width: w,
        height: h,
        format: IsolateImageFormat.png,
      );
      final decoded = img.decodeImage(png)!;
      final px = decoded.getPixel(0, 0);
      expect(px.r, 255, reason: 'view offset must be honoured (not 99 junk)');
      expect(px.g, 0);
      expect(px.b, 0);
    });
  });
}
