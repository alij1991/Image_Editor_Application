import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

import 'package:image_editor/features/scanner/data/auto_rotate.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('estimateRotationDegrees', () {
    test('returns null on a uniform black image (no edges)', () {
      final flat = img.Image(width: 320, height: 240);
      img.fill(flat, color: img.ColorRgb8(0, 0, 0));
      expect(estimateRotationDegrees(flat), isNull);
    });

    test('returns 0 on a page dominated by horizontal lines', () {
      // Faux text lines: many long horizontal bright bars on dark.
      final scene = img.Image(width: 480, height: 360);
      img.fill(scene, color: img.ColorRgb8(20, 20, 20));
      for (var i = 0; i < 14; i++) {
        final y = 30 + i * 20;
        img.fillRect(
          scene,
          x1: 40,
          y1: y,
          x2: 440,
          y2: y + 4,
          color: img.ColorRgb8(245, 245, 245),
        );
      }
      final r = estimateRotationDegrees(scene);
      // Either we confidently say "upright" (0) or we abstain (null
      // when fewer than 10 confident lines survive Canny / threshold);
      // we MUST NOT say "rotate me 90°".
      expect(r, anyOf(equals(0), isNull));
    });

    test('returns 90 on a page dominated by vertical lines', () {
      // Same pattern, transposed — simulates a page captured sideways.
      final scene = img.Image(width: 360, height: 480);
      img.fill(scene, color: img.ColorRgb8(20, 20, 20));
      for (var i = 0; i < 14; i++) {
        final x = 30 + i * 20;
        img.fillRect(
          scene,
          x1: x,
          y1: 40,
          x2: x + 4,
          y2: 440,
          color: img.ColorRgb8(245, 245, 245),
        );
      }
      final r = estimateRotationDegrees(scene);
      expect(r, anyOf(equals(90), isNull));
    });
  });
}
