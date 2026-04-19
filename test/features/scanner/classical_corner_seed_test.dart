import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

import 'package:image_editor/features/scanner/infrastructure/classical_corner_seed.dart';
import 'package:image_editor/features/scanner/domain/models/scan_models.dart';

/// Persist [image] as a JPEG inside an OS temp dir so the seeder's
/// File-based read path is exercised end-to-end.
Future<String> _writeJpeg(img.Image image, String name) async {
  final dir = Directory.systemTemp.createTempSync('seed_test');
  final file = File('${dir.path}/$name');
  await file.writeAsBytes(
    Uint8List.fromList(img.encodeJpg(image, quality: 85)),
  );
  return file.path;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const seeder = ClassicalCornerSeed();

  group('ClassicalCornerSeed.seed', () {
    test('returns inset fallback when the image path does not decode',
        () async {
      final result = await seeder.seed('/nonexistent/that/cannot/decode.jpg');
      expect(result.fellBack, isTrue);
      expect(result.corners.tl.x, closeTo(0.05, 1e-6));
      expect(result.corners.br.x, closeTo(0.95, 1e-6));
    });

    test('returns inset fallback for a uniform black image (no edges)',
        () async {
      final flat = img.Image(width: 256, height: 256);
      img.fill(flat, color: img.ColorRgb8(0, 0, 0));
      final path = await _writeJpeg(flat, 'flat.jpg');
      final result = await seeder.seed(path);
      // Either no edges or the bounding box covers the full frame —
      // both routes mark fellBack=true.
      expect(result.fellBack, isTrue);
    });

    test('returns fellBack when the bounding box covers the whole frame',
        () async {
      // A noisy texture has edges everywhere — the bounding box of the
      // edge cloud covers the entire frame, so the seeder treats this
      // as "no usable page boundary" and falls back.
      final noisy = img.Image(width: 256, height: 256);
      for (var y = 0; y < noisy.height; y++) {
        for (var x = 0; x < noisy.width; x++) {
          final v = ((x * 31 + y * 17) ^ (x * y)) & 0xFF;
          noisy.setPixelRgb(x, y, v, v, v);
        }
      }
      final path = await _writeJpeg(noisy, 'noisy.jpg');
      final result = await seeder.seed(path);
      expect(result.fellBack, isTrue);
    });

    test('finds tight corners around a bright rectangle on a dark field',
        () async {
      // Dark background with a bright central rectangle — Sobel
      // magnitude peaks at the rectangle border, the bounding box of
      // the edge mask should hug the rectangle.
      final scene = img.Image(width: 320, height: 240);
      img.fill(scene, color: img.ColorRgb8(20, 20, 20));
      img.fillRect(
        scene,
        x1: 60,
        y1: 50,
        x2: 260,
        y2: 200,
        color: img.ColorRgb8(240, 240, 240),
      );
      final path = await _writeJpeg(scene, 'rect.jpg');
      final result = await seeder.seed(path);
      // Should NOT fall back — there's a clear page-like edge here.
      expect(result.fellBack, isFalse,
          reason: 'expected real corners, got inset fallback');
      // Box should roughly hug the rectangle (tolerant — Sobel +
      // downscale + percentile thresholding leaves slack).
      final c = result.corners;
      expect(c.tl.x, lessThan(0.35));
      expect(c.tl.y, lessThan(0.35));
      expect(c.br.x, greaterThan(0.65));
      expect(c.br.y, greaterThan(0.65));
    });
  });

  group('SeedResult', () {
    test('SeedResult holds the corners and fellBack flag verbatim', () {
      final c = Corners.inset();
      final r = SeedResult(corners: c, fellBack: true);
      expect(identical(r.corners, c), isTrue);
      expect(r.fellBack, isTrue);
    });
  });
}
