import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

import 'package:image_editor/features/editor/data/export_service.dart';

/// Pure-API tests for [ExportService]. The render pass needs a Flutter
/// engine to run shader programs, so we cover everything that doesn't
/// touch the GPU here:
///   - format enum metadata
///   - decoder against a tiny PNG fixture written to disk
///   - encoder against a synthetic [ui.Image]
///   - error paths (missing file, bad quality, WebP not supported)
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<File> writeTinyPngToDisk(String name) async {
    final tmp = Directory.systemTemp.createTempSync('export_test');
    final file = File('${tmp.path}/$name');
    // 4×4 red square.
    final bytes = img.encodePng(
      img.Image(width: 4, height: 4)..clear(img.ColorRgb8(255, 0, 0)),
    );
    await file.writeAsBytes(bytes);
    return file;
  }

  Future<ui.Image> tinySolidImage(int w, int h, int rgba) async {
    final pixels = Uint8List(w * h * 4);
    for (int i = 0; i < w * h; i++) {
      pixels[i * 4 + 0] = (rgba >> 24) & 0xff;
      pixels[i * 4 + 1] = (rgba >> 16) & 0xff;
      pixels[i * 4 + 2] = (rgba >> 8) & 0xff;
      pixels[i * 4 + 3] = rgba & 0xff;
    }
    final completer = Completer<ui.Image>();
    ui.decodeImageFromPixels(
      pixels,
      w,
      h,
      ui.PixelFormat.rgba8888,
      completer.complete,
    );
    return completer.future;
  }

  group('ExportFormat', () {
    test('every format has label, mime, and extension', () {
      for (final f in ExportFormat.values) {
        expect(f.label, isNotEmpty);
        expect(f.mimeType, contains('/'));
        expect(f.extension, startsWith('.'));
      }
    });

    test('PNG and WebP support alpha; JPEG does not', () {
      expect(ExportFormat.jpeg.supportsAlpha, false);
      expect(ExportFormat.png.supportsAlpha, true);
      expect(ExportFormat.webp.supportsAlpha, true);
    });
  });

  group('ExportService.decodeFullRes', () {
    test('decodes a real PNG from disk', () async {
      final svc = ExportService();
      final file = await writeTinyPngToDisk('tiny.png');
      try {
        final image = await svc.decodeFullRes(sourcePath: file.path);
        expect(image.width, 4);
        expect(image.height, 4);
        image.dispose();
      } finally {
        file.parent.deleteSync(recursive: true);
      }
    });

    test('throws ExportException when source file is missing', () async {
      final svc = ExportService();
      try {
        await svc.decodeFullRes(sourcePath: '/tmp/does-not-exist.png');
        fail('expected ExportException');
      } on ExportException catch (e) {
        expect(e.message, contains('not found'));
      }
    });

    test('respects maxLongEdge by downscaling the long axis', () async {
      final svc = ExportService();
      final tmp = Directory.systemTemp.createTempSync('export_test');
      final file = File('${tmp.path}/big.png');
      // 200×100 — landscape; clamping long edge to 50 should give 50×25.
      await file.writeAsBytes(img.encodePng(
        img.Image(width: 200, height: 100)..clear(img.ColorRgb8(0, 128, 0)),
      ));
      try {
        final image = await svc.decodeFullRes(
          sourcePath: file.path,
          maxLongEdge: 50,
        );
        expect(image.width, 50);
        expect(image.height, 25);
        image.dispose();
      } finally {
        tmp.deleteSync(recursive: true);
      }
    });
  });

  group('ExportService.encode', () {
    test('JPEG encode rejects out-of-range quality', () async {
      final svc = ExportService();
      final image = await tinySolidImage(2, 2, 0xff8844ff);
      try {
        await svc.encode(image: image, format: ExportFormat.jpeg, quality: 0);
        fail('expected ExportException for q=0');
      } on ExportException catch (e) {
        expect(e.message, contains('Quality'));
      }
      try {
        await svc.encode(
            image: image, format: ExportFormat.jpeg, quality: 101);
        fail('expected ExportException for q=101');
      } on ExportException catch (e) {
        expect(e.message, contains('Quality'));
      } finally {
        image.dispose();
      }
    });

    test('JPEG encode produces a valid JPEG byte stream', () async {
      final svc = ExportService();
      final image = await tinySolidImage(8, 8, 0xff112233);
      try {
        final bytes = await svc.encode(
            image: image, format: ExportFormat.jpeg, quality: 80);
        // JPEGs always start with the SOI marker FF D8 and end with EOI FF D9.
        expect(bytes[0], 0xFF);
        expect(bytes[1], 0xD8);
        expect(bytes[bytes.length - 2], 0xFF);
        expect(bytes[bytes.length - 1], 0xD9);
      } finally {
        image.dispose();
      }
    });

    test('PNG encode produces a valid PNG byte stream', () async {
      final svc = ExportService();
      final image = await tinySolidImage(8, 8, 0xffaabbcc);
      try {
        final bytes =
            await svc.encode(image: image, format: ExportFormat.png);
        // PNG signature: 89 50 4E 47 0D 0A 1A 0A
        expect(
          bytes.sublist(0, 8),
          equals([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]),
        );
      } finally {
        image.dispose();
      }
    });

    test('WebP encode is currently unsupported and surfaces a coaching error',
        () async {
      final svc = ExportService();
      final image = await tinySolidImage(2, 2, 0xff000000);
      try {
        await svc.encode(image: image, format: ExportFormat.webp);
        fail('expected ExportException for unsupported WebP');
      } on ExportException catch (e) {
        expect(e.message, contains('WebP'));
        expect(e.message, contains('JPEG or PNG'));
      } finally {
        image.dispose();
      }
    });
  });

  group('ExportException', () {
    test('toString includes the cause when present', () {
      const e = ExportException('boom', cause: 'underlying');
      expect(e.toString(), contains('ExportException'));
      expect(e.toString(), contains('boom'));
      expect(e.toString(), contains('underlying'));
    });
  });
}
