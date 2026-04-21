import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

import 'package:image_editor/features/scanner/data/image_processor.dart';
import 'package:image_editor/features/scanner/domain/models/scan_models.dart';

/// Tests for [perspectiveWarpDartFallback] — the pure-Dart bilinear warp
/// that runs when OpenCV is unavailable (test runner / unsupported
/// platform). In release builds [_perspectiveWarp] short-circuits to the
/// native OpenCV path and the tree-shaker removes this function entirely,
/// so these tests also serve as documentation of the test-only seam.
void main() {
  group('perspectiveWarpDartFallback', () {
    test('full-rect identity warp preserves source dimensions', () {
      // Corners.full() maps the entire image to itself; output should
      // match input w × h exactly.
      final src = img.Image(width: 120, height: 80);
      img.fill(src, color: img.ColorRgb8(128, 128, 128));

      final out = perspectiveWarpDartFallback(src, Corners.full());

      expect(out.width, 120);
      expect(out.height, 80);
    });

    test('inset 5% corners shrink output to ~90% of source edge', () {
      // Corners.inset(0.05): each side moves 5% inward → inner rect
      // spans 90% of source width/height.  _outputDimsFor averages the
      // two opposite-edge distances:
      //   widthTop = widthBot = heightL = heightR = 200 × 0.90 = 180
      // → outW = outH = 180.
      final src = img.Image(width: 200, height: 200);
      img.fill(src, color: img.ColorRgb8(200, 200, 200));

      final out = perspectiveWarpDartFallback(src, Corners.inset(0.05));

      expect(out.width, 180);
      expect(out.height, 180);
    });

    test('output pixels are in 0–255 RGB range', () {
      // Solid red source — every output pixel should be near (255, 0, 0).
      final src = img.Image(width: 64, height: 64);
      img.fill(src, color: img.ColorRgb8(255, 0, 0));

      final out = perspectiveWarpDartFallback(src, Corners.inset(0.1));

      // Sample the centre pixel.
      final cx = out.width ~/ 2;
      final cy = out.height ~/ 2;
      final px = out.getPixel(cx, cy);
      expect(px.r, greaterThan(200),
          reason: 'red channel should be close to 255');
      expect(px.g, lessThan(55), reason: 'green channel should be near 0');
      expect(px.b, lessThan(55), reason: 'blue channel should be near 0');
    });

    test('non-rectangular warp still produces a valid image', () {
      // Slight perspective distortion: push the top-right corner inward.
      const skewed = Corners(
        Point2(0.0, 0.0),
        Point2(0.8, 0.05),  // top-right shifted left + down
        Point2(1.0, 1.0),
        Point2(0.0, 1.0),
      );
      final src = img.Image(width: 200, height: 200);
      img.fill(src, color: img.ColorRgb8(100, 150, 200));

      final out = perspectiveWarpDartFallback(src, skewed);

      expect(out.width, greaterThan(0));
      expect(out.height, greaterThan(0));
    });
  });
}
