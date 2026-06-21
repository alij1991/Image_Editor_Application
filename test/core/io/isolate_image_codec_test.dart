import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

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

    test('round-trips through a view-backed RGBA buffer', () async {
      // A Uint8List view with a non-zero offset must still encode the
      // intended pixels (guards the .buffer handling across the isolate).
      final backing = Uint8List(8 + 4 * 4)..fillRange(0, 8, 7);
      final view = Uint8List.view(backing.buffer, 8, 4 * 4)
        ..fillRange(0, 16, 255);
      final bytes = await encodeRgbaInIsolate(
        rgba: Uint8List.fromList(view), // normalise to offset 0
        width: 2,
        height: 2,
        format: IsolateImageFormat.png,
      );
      expect(bytes.sublist(0, 4), [0x89, 0x50, 0x4E, 0x47]);
    });
  });

  group('reencodeToJpegInIsolate', () {
    test('re-encodes a PNG to JPEG', () async {
      final png = await encodeRgbaInIsolate(
        rgba: _solidRgba(8, 8),
        width: 8,
        height: 8,
        format: IsolateImageFormat.png,
      );
      final jpeg = await reencodeToJpegInIsolate(bytes: png, quality: 80);
      expect(jpeg, isNotNull);
      expect(jpeg![0], 0xFF);
      expect(jpeg[1], 0xD8);
    });

    test('returns null for undecodable bytes', () async {
      final junk = Uint8List.fromList(List<int>.filled(64, 0x42));
      expect(await reencodeToJpegInIsolate(bytes: junk, quality: 80), isNull);
    });
  });
}
