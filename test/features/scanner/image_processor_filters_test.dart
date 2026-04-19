import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

import 'package:image_editor/features/scanner/data/image_processor.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('binarizeWithOpenCv', () {
    test('converts a page with text-like strokes to black-and-white', () {
      // White page with several thin horizontal strokes and a thin
      // vertical stroke — realistic text stroke width (~3 px) so the
      // adaptive 31×31 window's local mean stays bright. Adaptive
      // threshold misbehaves on strokes wider than the window
      // because the interior of a fully-inked window has a mean
      // equal to the ink itself; that's a property of the algorithm,
      // not a bug in our wrapper.
      final scene = img.Image(width: 480, height: 360);
      img.fill(scene, color: img.ColorRgb8(245, 245, 245));
      // Five horizontal "text lines", 3 px tall, every 40 px.
      for (var i = 0; i < 5; i++) {
        final y = 60 + i * 40;
        img.fillRect(scene,
            x1: 60,
            y1: y,
            x2: 420,
            y2: y + 2,
            color: img.ColorRgb8(20, 20, 20));
      }
      // One vertical 3 px stroke down the middle of the gap.
      img.fillRect(scene,
          x1: 240,
          y1: 60,
          x2: 242,
          y2: 250,
          color: img.ColorRgb8(20, 20, 20));

      final out = binarizeWithOpenCv(scene);
      expect(out, isNotNull);

      // Sample a stroke pixel (centre of the first line) and a
      // background pixel (between two lines, away from any stroke).
      final stroke = out!.getPixel(150, 61);
      final bg = out.getPixel(100, 80);
      expect(stroke.r, lessThan(60));
      expect(bg.r, greaterThan(195));
    });

    test('returns a 3-channel RGB image (not the raw 1-channel mask)',
        () {
      final scene = img.Image(width: 64, height: 64);
      img.fill(scene, color: img.ColorRgb8(245, 245, 245));
      final out = binarizeWithOpenCv(scene);
      expect(out, isNotNull);
      expect(out!.numChannels, equals(3));
    });
  });

  group('magicColorWithOpenCv', () {
    test('lifts a darkened page back toward neutral brightness', () {
      // Page with a heavy left-to-right brightness gradient — the
      // sort of shadow you'd get from a hand-held capture under a
      // window. The illumination-normalisation divide should leave
      // the output far more uniformly bright than the input.
      final scene = img.Image(width: 320, height: 240);
      for (var y = 0; y < scene.height; y++) {
        for (var x = 0; x < scene.width; x++) {
          // Linear ramp 60..220 across x.
          final v = (60 + (x / scene.width) * 160).round();
          scene.setPixelRgb(x, y, v, v, v);
        }
      }

      final out = magicColorWithOpenCv(scene);
      expect(out, isNotNull);

      // Sample two columns: dark side (10% across) and bright side
      // (90% across). Unprocessed contrast is ~v(60) vs v(220);
      // after illumination normalisation the gap should shrink
      // significantly — we don't expect zero, but a clear narrowing.
      final dark = out!.getPixel((out.width * 0.1).round(), out.height ~/ 2);
      final bright =
          out.getPixel((out.width * 0.9).round(), out.height ~/ 2);
      const inputGap = 220 - 60;
      final outputGap = (bright.r - dark.r).abs();
      expect(outputGap, lessThan(inputGap * 0.6),
          reason: 'shadow removal should narrow brightness gap');
    });

    test('returns a 3-channel RGB image at source resolution', () {
      final scene = img.Image(width: 128, height: 96);
      img.fill(scene, color: img.ColorRgb8(180, 180, 180));
      final out = magicColorWithOpenCv(scene);
      expect(out, isNotNull);
      expect(out!.width, equals(128));
      expect(out.height, equals(96));
      expect(out.numChannels, equals(3));
    });
  });
}
