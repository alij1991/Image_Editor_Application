import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

import 'package:image_editor/features/scanner/domain/models/scan_models.dart';
import 'package:image_editor/features/scanner/infrastructure/classical_corner_seed.dart';
import 'package:image_editor/features/scanner/infrastructure/opencv_corner_seed.dart';

Future<String> _writeJpeg(img.Image image, String name) async {
  final dir = Directory.systemTemp.createTempSync('opencv_seed_test');
  final file = File('${dir.path}/$name');
  await file.writeAsBytes(
    Uint8List.fromList(img.encodeJpg(image, quality: 88)),
  );
  return file.path;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const seeder = OpenCvCornerSeed();

  group('OpenCvCornerSeed', () {
    test('falls back to Sobel + inset for an empty file path', () async {
      final result = await seeder.seed('/nonexistent/path.jpg');
      // Sobel fallback returns inset, so fellBack should be true and
      // corners should match the standard inset shape.
      expect(result.fellBack, isTrue);
      expect(result.corners.tl.x, closeTo(0.05, 1e-6));
    });

    test('falls back to Sobel for a uniform black image (no edges)',
        () async {
      final flat = img.Image(width: 320, height: 240);
      img.fill(flat, color: img.ColorRgb8(0, 0, 0));
      final path = await _writeJpeg(flat, 'flat.jpg');
      final result = await seeder.seed(path);
      expect(result.fellBack, isTrue);
    });

    test('finds a tight quad on a white page over dark background',
        () async {
      // Bright rectangle on a dark field — Canny + findContours should
      // pick the rectangle's outline as the dominant 4-vertex contour
      // and return a much tighter quad than the Sobel bounding-box
      // heuristic could on the same fixture.
      final scene = img.Image(width: 480, height: 360);
      img.fill(scene, color: img.ColorRgb8(15, 15, 15));
      img.fillRect(
        scene,
        x1: 80,
        y1: 60,
        x2: 400,
        y2: 300,
        color: img.ColorRgb8(245, 245, 245),
      );
      final path = await _writeJpeg(scene, 'rect.jpg');
      final result = await seeder.seed(path);
      expect(result.fellBack, isFalse,
          reason: 'expected a real OpenCV quad, got fallback');
      final c = result.corners;
      // Corners should hug the rectangle (within a couple of percent).
      expect(c.tl.x, closeTo(80 / 479, 0.04));
      expect(c.tl.y, closeTo(60 / 359, 0.06));
      expect(c.br.x, closeTo(400 / 479, 0.04));
      expect(c.br.y, closeTo(300 / 359, 0.06));
    });

    test('delegates to the injected fallback when no quad is found',
        () async {
      var fallbackHits = 0;
      final tracker = _TrackerSeeder(() => fallbackHits++);
      final seederWithTracker = OpenCvCornerSeed(fallback: tracker);

      final flat = img.Image(width: 240, height: 180);
      img.fill(flat, color: img.ColorRgb8(0, 0, 0));
      final path = await _writeJpeg(flat, 'flat2.jpg');
      await seederWithTracker.seed(path);
      expect(fallbackHits, equals(1));
    });
  });
}

/// Test double that records how many times its [seed] method ran so
/// the OpenCV chain can be observed delegating to a fallback.
class _TrackerSeeder implements CornerSeeder {
  _TrackerSeeder(this.onSeed);
  final void Function() onSeed;

  @override
  Future<SeedResult> seed(String imagePath) async {
    onSeed();
    return SeedResult(corners: Corners.inset(), fellBack: true);
  }

  @override
  Future<List<SeedResult>> seedBatch(List<String> imagePaths) async {
    final results = <SeedResult>[];
    for (final path in imagePaths) {
      results.add(await seed(path));
    }
    return results;
  }
}
