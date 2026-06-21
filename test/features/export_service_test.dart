import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

import 'package:image_editor/engine/pipeline/geometry_state.dart';
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

  group('renderToImage geometry (XVI.115)', () {
    // renderToImage runs WITHOUT shader programs when `passes` is empty
    // (ShaderRenderer just drawImageRects the source), so the geometry
    // math is exercisable in flutter_test via picture.toImage.
    //
    // Oracle: a 16×8 source split into four solid quadrants
    // (TL=red, TR=green, BL=blue, BR=white). For each geometry the
    // expected output dims + which SOURCE quadrant lands at each OUTPUT
    // quadrant were independently derived three ways and adjudicated
    // against the ImageCanvas widget tree (geometry-derivation
    // workflow; release-audit C1). Export must reproduce the preview.

    Future<ui.Image> quadrantSource() {
      const w = 16, h = 8;
      final px = Uint8List(w * h * 4);
      void set(int x, int y, int r, int g, int b) {
        final i = (y * w + x) * 4;
        px[i] = r;
        px[i + 1] = g;
        px[i + 2] = b;
        px[i + 3] = 255;
      }

      for (var y = 0; y < h; y++) {
        for (var x = 0; x < w; x++) {
          final left = x < 8;
          final top = y < 4;
          if (top && left) {
            set(x, y, 255, 0, 0); // TL red
          } else if (top && !left) {
            set(x, y, 0, 255, 0); // TR green
          } else if (!top && left) {
            set(x, y, 0, 0, 255); // BL blue
          } else {
            set(x, y, 255, 255, 255); // BR white
          }
        }
      }
      final c = Completer<ui.Image>();
      ui.decodeImageFromPixels(px, w, h, ui.PixelFormat.rgba8888, c.complete);
      return c.future;
    }

    String nearest(int r, int g, int b) {
      const palette = <String, List<int>>{
        'red': [255, 0, 0],
        'green': [0, 255, 0],
        'blue': [0, 0, 255],
        'white': [255, 255, 255],
      };
      var best = '';
      var bestD = 1 << 30;
      palette.forEach((name, c) {
        final d = (r - c[0]) * (r - c[0]) +
            (g - c[1]) * (g - c[1]) +
            (b - c[2]) * (b - c[2]);
        if (d < bestD) {
          bestD = d;
          best = name;
        }
      });
      return best;
    }

    // Sample each output quadrant CENTER (far from seams → robust to
    // any bilinear edge bleed).
    Future<Map<String, String>> cornerColors(ui.Image im) async {
      final bd = await im.toByteData(format: ui.ImageByteFormat.rawRgba);
      final raw = bd!.buffer.asUint8List();
      String at(double fx, double fy) {
        final x = (fx * im.width).floor().clamp(0, im.width - 1);
        final y = (fy * im.height).floor().clamp(0, im.height - 1);
        final i = (y * im.width + x) * 4;
        return nearest(raw[i], raw[i + 1], raw[i + 2]);
      }

      return {
        'TL': at(0.25, 0.25),
        'TR': at(0.75, 0.25),
        'BL': at(0.25, 0.75),
        'BR': at(0.75, 0.75),
      };
    }

    final cases = <String, (GeometryState, int, int, Map<String, String>)>{
      'identity': (
        const GeometryState(),
        16,
        8,
        {'TL': 'red', 'TR': 'green', 'BL': 'blue', 'BR': 'white'},
      ),
      'rot90 (CW)': (
        const GeometryState(rotationSteps: 1),
        8,
        16,
        {'TL': 'blue', 'TR': 'red', 'BL': 'white', 'BR': 'green'},
      ),
      'rot180': (
        const GeometryState(rotationSteps: 2),
        16,
        8,
        {'TL': 'white', 'TR': 'blue', 'BL': 'green', 'BR': 'red'},
      ),
      'rot270': (
        const GeometryState(rotationSteps: 3),
        8,
        16,
        {'TL': 'green', 'TR': 'white', 'BL': 'red', 'BR': 'blue'},
      ),
      'flipH': (
        const GeometryState(flipH: true),
        16,
        8,
        {'TL': 'green', 'TR': 'red', 'BL': 'white', 'BR': 'blue'},
      ),
      'flipV': (
        const GeometryState(flipV: true),
        16,
        8,
        {'TL': 'blue', 'TR': 'white', 'BL': 'red', 'BR': 'green'},
      ),
      'rot90+flipH': (
        const GeometryState(rotationSteps: 1, flipH: true),
        8,
        16,
        {'TL': 'white', 'TR': 'green', 'BL': 'blue', 'BR': 'red'},
      ),
    };

    for (final entry in cases.entries) {
      test('${entry.key} — output dims + quadrant mapping', () async {
        final svc = ExportService();
        final src = await quadrantSource();
        try {
          final (geom, expW, expH, expCorners) = entry.value;
          final out = await svc.renderToImage(
            source: src,
            passes: const [],
            geometry: geom,
          );
          try {
            expect(out.width, expW, reason: '${entry.key} width');
            expect(out.height, expH, reason: '${entry.key} height');
            expect(await cornerColors(out), expCorners,
                reason: '${entry.key} quadrant mapping');
          } finally {
            out.dispose();
          }
        } finally {
          src.dispose();
        }
      });
    }

    test('crop (right half) — dims + content, no rotation', () async {
      final svc = ExportService();
      final src = await quadrantSource();
      try {
        final out = await svc.renderToImage(
          source: src,
          passes: const [],
          geometry: const GeometryState(
            cropRect: CropRect(left: 0.5, top: 0, right: 1, bottom: 1),
          ),
        );
        try {
          expect(out.width, 8); // 0.5 × 16
          expect(out.height, 8); // 1.0 × 8
          final c = await cornerColors(out);
          // Right half = TR(green) over BR(white).
          expect(c['TL'], 'green');
          expect(c['TR'], 'green');
          expect(c['BL'], 'white');
          expect(c['BR'], 'white');
        } finally {
          out.dispose();
        }
      } finally {
        src.dispose();
      }
    });

    test('crop + rot90 — cropped extents swap onto the output axes',
        () async {
      final svc = ExportService();
      final src = await quadrantSource();
      try {
        // Top-left quarter crop: cropW = 0.5×16 = 8, cropH = 0.5×8 = 4.
        // Identity would be 8×4; the 90° turn swaps it to 4×8.
        final out = await svc.renderToImage(
          source: src,
          passes: const [],
          geometry: const GeometryState(
            rotationSteps: 1,
            cropRect: CropRect(left: 0, top: 0, right: 0.5, bottom: 0.5),
          ),
        );
        try {
          expect(out.width, 4);
          expect(out.height, 8);
        } finally {
          out.dispose();
        }
      } finally {
        src.dispose();
      }
    });

    test('straighten rotates content + exposes transparent corners',
        () async {
      final svc = ExportService();
      // Solid red so only geometry (not content) explains the result.
      final src = await tinySolidImage(32, 32, 0xff0000ff);
      try {
        final out = await svc.renderToImage(
          source: src,
          passes: const [],
          geometry: const GeometryState(straightenDegrees: 25),
        );
        try {
          // No crop → dims unchanged.
          expect(out.width, 32);
          expect(out.height, 32);
          final bd = await out.toByteData(format: ui.ImageByteFormat.rawRgba);
          final raw = bd!.buffer.asUint8List();
          int alphaAt(int x, int y) => raw[(y * out.width + x) * 4 + 3];
          // Center stays opaque; a corner is uncovered (transparent)
          // because straighten has no cover-scale — mirrors the preview.
          expect(alphaAt(16, 16), 255, reason: 'center stays opaque');
          expect(alphaAt(0, 0), lessThan(128), reason: 'corner uncovered');
        } finally {
          out.dispose();
        }
      } finally {
        src.dispose();
      }
    });
  });
}
