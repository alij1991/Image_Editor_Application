import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';

import 'package:image_editor/engine/geometry/smart_crop_placer.dart';

/// Phase XVI.38 — pin the smart-crop math against face placement,
/// aspect snap, and bounds-slide behaviour. The placer is what the
/// SMART CROP chips in the GeometryPanel call on tap, so a regression
/// here is a regression in user-visible UX.
void main() {
  const placer = SmartCropPlacer();

  group('SmartCropPlacer.suggest no-face fallback (XVI.38)', () {
    test('square crop on a 1000x1500 portrait centres on image', () {
      final r = placer.suggest(
        imageWidth: 1000,
        imageHeight: 1500,
        aspect: SmartCropPlacer.aspectSquare,
      );
      expect(r, isNotNull);
      // Aspect should be 1:1 → width = height in normalised space.
      // Image is 1000×1500; the rect's width should equal its height
      // in pixel space, so we expect the rect's normalised width
      // (~1000/1500 = 0.667) to be larger than its normalised height
      // (~1.0) — wait no. 1:1 in pixels means equal width/height in
      // pixels. Width 1000 / height 1000 → norm width 1.0, height 0.667.
      final wPx = (r!.right - r.left) * 1000;
      final hPx = (r.bottom - r.top) * 1500;
      expect(wPx, closeTo(hPx, 1.0),
          reason: 'square crop must have equal pixel width + height');
      // Centred → centre of crop sits near (500, 750).
      final cx = (r.left + r.right) / 2 * 1000;
      final cy = (r.top + r.bottom) / 2 * 1500;
      expect(cx, closeTo(500, 1.0));
      expect(cy, closeTo(750, 1.0));
    });

    test('16:9 crop on a 1500x1000 landscape contracts height', () {
      // Image is 3:2 (1.5); target is 16:9 (1.78). Wider target → keep
      // width, contract height.
      final r = placer.suggest(
        imageWidth: 1500,
        imageHeight: 1000,
        aspect: SmartCropPlacer.aspectLandscape169,
      );
      expect(r, isNotNull);
      final wPx = (r!.right - r.left) * 1500;
      final hPx = (r.bottom - r.top) * 1000;
      expect(wPx / hPx, closeTo(16 / 9, 0.01));
    });

    test('full-frame square on a square image is rejected (no-op)', () {
      // 1:1 on a 1000×1000 image is the full frame; the placer
      // returns null so the chip's snackbar can flag it.
      final r = placer.suggest(
        imageWidth: 1000,
        imageHeight: 1000,
        aspect: SmartCropPlacer.aspectSquare,
      );
      expect(r, isNull);
    });

    test('degenerate dimensions return null', () {
      expect(
          placer.suggest(
              imageWidth: 0,
              imageHeight: 100,
              aspect: SmartCropPlacer.aspectSquare),
          isNull);
      expect(
          placer.suggest(
              imageWidth: 100,
              imageHeight: 0,
              aspect: SmartCropPlacer.aspectSquare),
          isNull);
      expect(
          placer.suggest(
              imageWidth: 100, imageHeight: 100, aspect: 0),
          isNull);
    });
  });

  group('SmartCropPlacer.suggest face-centred (XVI.38)', () {
    test('largest face wins when multiple are present', () {
      // Two faces: a tiny one in the top-left, a large one in the
      // lower-right. The crop must centre on the large one.
      const small = Rect.fromLTWH(10, 10, 50, 50);
      const big = Rect.fromLTWH(700, 1000, 200, 250);
      final r = placer.suggest(
        imageWidth: 1000,
        imageHeight: 1500,
        aspect: SmartCropPlacer.aspectPortrait45,
        faces: const [small, big],
      );
      expect(r, isNotNull);
      // Centre of the crop should be near the big face's centre
      // (800, 1125). Allow some slop because the bounds-slide kicks
      // in for any rect that would cross the image edges.
      final cx = (r!.left + r.right) / 2 * 1000;
      final cy = (r.top + r.bottom) / 2 * 1500;
      expect(cx, closeTo(800, 100),
          reason: 'centre should track the largest face\'s x');
      expect(cy, closeTo(1125, 200),
          reason: 'centre should track the largest face\'s y');
    });

    test('face crop respects the requested aspect', () {
      const face = Rect.fromLTWH(400, 400, 200, 200);
      final r = placer.suggest(
        imageWidth: 1200,
        imageHeight: 1500,
        aspect: SmartCropPlacer.aspectPortrait45,
        faces: const [face],
      );
      expect(r, isNotNull);
      final wPx = (r!.right - r.left) * 1200;
      final hPx = (r.bottom - r.top) * 1500;
      // 4:5 = 0.8; allow 5% slop because bounds-clamping can drift
      // the aspect when the target rect bumps against an edge.
      expect(wPx / hPx, closeTo(4 / 5, 0.05));
    });

    test('face near image edge slides crop into bounds', () {
      // Face is in the top-right corner — the centred crop would
      // overhang both edges, so the placer slides it in.
      const face = Rect.fromLTWH(950, 50, 200, 200);
      final r = placer.suggest(
        imageWidth: 1000,
        imageHeight: 1500,
        aspect: SmartCropPlacer.aspectSquare,
        faces: const [face],
      );
      expect(r, isNotNull);
      // Every edge stays inside [0, 1].
      expect(r!.left, greaterThanOrEqualTo(0));
      expect(r.top, greaterThanOrEqualTo(0));
      expect(r.right, lessThanOrEqualTo(1));
      expect(r.bottom, lessThanOrEqualTo(1));
    });

    test('null faces and empty faces both fall back to image centre', () {
      final centred = placer.suggest(
        imageWidth: 1000,
        imageHeight: 1500,
        aspect: SmartCropPlacer.aspectSquare,
      );
      final centredEmpty = placer.suggest(
        imageWidth: 1000,
        imageHeight: 1500,
        aspect: SmartCropPlacer.aspectSquare,
        faces: const [],
      );
      expect(centred, isNotNull);
      expect(centredEmpty, isNotNull);
      // Both should produce identical rects.
      expect(centred!.left, centredEmpty!.left);
      expect(centred.top, centredEmpty.top);
      expect(centred.right, centredEmpty.right);
      expect(centred.bottom, centredEmpty.bottom);
    });

    test('zero-area faces are ignored (degrades to image centre)', () {
      const ghostFace = Rect.fromLTWH(500, 500, 0, 0);
      final r = placer.suggest(
        imageWidth: 1000,
        imageHeight: 1500,
        aspect: SmartCropPlacer.aspectSquare,
        faces: const [ghostFace],
      );
      expect(r, isNotNull);
      // Falls back to image-centre (same result as null faces).
      final fallback = placer.suggest(
        imageWidth: 1000,
        imageHeight: 1500,
        aspect: SmartCropPlacer.aspectSquare,
      );
      expect(r!.left, fallback!.left);
      expect(r.right, fallback.right);
    });
  });
}
