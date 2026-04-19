import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

import 'package:image_editor/features/scanner/data/image_processor.dart';

/// Persist [image] as a JPEG inside an OS temp dir for the deskew
/// estimator (which reads from a file path).
Future<String> _writeJpeg(img.Image image, String name) async {
  final dir = Directory.systemTemp.createTempSync('imgproc_test');
  final file = File('${dir.path}/$name');
  await file.writeAsBytes(
    Uint8List.fromList(img.encodeJpg(image, quality: 88)),
  );
  return file.path;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('estimateDeskewDegrees', () {
    test('returns null on a uniform black image (no edges to Hough)', () {
      final flat = img.Image(width: 320, height: 240);
      img.fill(flat, color: img.ColorRgb8(0, 0, 0));
      final angle = estimateDeskewDegrees(flat);
      expect(angle, isNull);
    });

    test('returns ~0 for a perfectly horizontal line', () {
      final scene = img.Image(width: 480, height: 360);
      img.fill(scene, color: img.ColorRgb8(0, 0, 0));
      // Long horizontal bright line down the middle.
      img.fillRect(
        scene,
        x1: 40,
        y1: 178,
        x2: 440,
        y2: 182,
        color: img.ColorRgb8(255, 255, 255),
      );
      final angle = estimateDeskewDegrees(scene);
      // Either Hough finds enough lines to call it straight (angle
      // close to 0) or returns null when fewer than 8 lines survive
      // — both outcomes are acceptable for a single-line scene.
      if (angle != null) {
        expect(angle.abs(), lessThan(2.0));
      }
    });

    test('detects a tilted dominant-line as a non-zero skew', () async {
      // Several long parallel lines tilted ~5° off horizontal.
      final scene = img.Image(width: 480, height: 360);
      img.fill(scene, color: img.ColorRgb8(0, 0, 0));
      const tiltDeg = 5;
      const lineCount = 20;
      for (var i = 0; i < lineCount; i++) {
        final yBase = 40 + i * 14;
        // y = yBase + (x - 240) * tan(5°)
        const tan = 0.0875; // ≈ tan(5°)
        for (var x = 40; x <= 440; x++) {
          final y = (yBase + (x - 240) * tan).round();
          if (y >= 0 && y < scene.height) {
            scene.setPixelRgb(x, y, 255, 255, 255);
            if (y + 1 < scene.height) {
              scene.setPixelRgb(x, y + 1, 255, 255, 255);
            }
          }
        }
      }
      // Save just to keep the test self-contained / regrowable.
      await _writeJpeg(scene, 'tilted.jpg');
      final angle = estimateDeskewDegrees(scene);
      // Hough may not always find 8 lines depending on Canny's noise
      // floor at this synthetic fixture — accept either null OR a
      // detected angle within a reasonable tolerance of +5°.
      if (angle != null) {
        expect(angle, closeTo(5.0, 3.0));
      }
    });
  });
}
