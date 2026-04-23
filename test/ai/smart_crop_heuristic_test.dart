import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';

import 'package:image_editor/ai/services/object_detection/coco_labels.dart';
import 'package:image_editor/ai/services/object_detection/object_detector_service.dart';
import 'package:image_editor/ai/services/object_detection/smart_crop_heuristic.dart';

ObjectDetection det({
  required double left,
  required double top,
  required double width,
  required double height,
  int classIndex = CocoLabels.personClass,
  double score = 0.9,
}) {
  return ObjectDetection(
    bbox: ui.Rect.fromLTWH(left, top, width, height),
    classIndex: classIndex,
    score: score,
  );
}

void main() {
  group('SmartCropHeuristic.pickCrop', () {
    const heuristic = SmartCropHeuristic();

    test('returns null for empty detections', () {
      final crop = heuristic.pickCrop(
        imageWidth: 1000,
        imageHeight: 1000,
        detections: const [],
      );
      expect(crop, isNull);
    });

    test('drops below-threshold detections', () {
      final crop = heuristic.pickCrop(
        imageWidth: 1000,
        imageHeight: 1000,
        detections: [
          det(left: 100, top: 100, width: 200, height: 200, score: 0.1),
        ],
      );
      expect(crop, isNull);
    });

    test('returns null when detection covers ≥98% of the frame', () {
      // Subject fills the image → smart crop is pointless.
      final crop = heuristic.pickCrop(
        imageWidth: 1000,
        imageHeight: 1000,
        detections: [det(left: 0, top: 0, width: 1000, height: 1000)],
      );
      expect(crop, isNull);
    });

    test('prefers a person over a higher-scored generic object', () {
      // Book at 0.9 vs person at 0.7: person still wins because of
      // the preferred-subject tier.
      final crop = heuristic.pickCrop(
        imageWidth: 1000,
        imageHeight: 1000,
        detections: [
          det(
            left: 0,
            top: 0,
            width: 100,
            height: 100,
            classIndex: CocoLabels.bookClass,
            score: 0.95,
          ),
          det(
            left: 400,
            top: 400,
            width: 100,
            height: 100,
            classIndex: CocoLabels.personClass,
            score: 0.7,
          ),
        ],
      );
      expect(crop, isNotNull);
      // Centre of the returned crop should be near the person
      // bbox centre (450, 450) — not the book centre (50, 50).
      final cx = (crop!.left + crop.right) * 500;
      final cy = (crop.top + crop.bottom) * 500;
      expect(cx, closeTo(450, 50));
      expect(cy, closeTo(450, 50));
    });

    test('snaps a square subject to 1:1 aspect', () {
      final crop = heuristic.pickCrop(
        imageWidth: 1000,
        imageHeight: 1000,
        detections: [det(left: 400, top: 400, width: 200, height: 200)],
      );
      expect(crop, isNotNull);
      // Expanded bbox width ≈ height (aspect ~1.0).
      final w = crop!.width * 1000;
      final h = crop.height * 1000;
      expect(w / h, closeTo(1.0, 0.02));
    });

    test('snaps a tall subject to 4:5 portrait', () {
      // bbox 200 × 250 → aspect 0.8 exactly → target 4:5.
      final crop = heuristic.pickCrop(
        imageWidth: 1000,
        imageHeight: 1000,
        detections: [det(left: 400, top: 300, width: 200, height: 250)],
      );
      expect(crop, isNotNull);
      final w = crop!.width * 1000;
      final h = crop.height * 1000;
      // Expanded to contain the bbox → w/h ≈ 0.8.
      expect(w / h, closeTo(0.8, 0.03));
    });

    test('clamps rect to image bounds when subject sits near the edge',
        () {
      // Subject in the corner (0, 0) forces left/top = 0 after sliding.
      final crop = heuristic.pickCrop(
        imageWidth: 1000,
        imageHeight: 1000,
        detections: [det(left: 0, top: 0, width: 200, height: 200)],
      );
      expect(crop, isNotNull);
      expect(crop!.left, lessThan(0.01));
      expect(crop.top, lessThan(0.01));
    });

    test('produces a normalized CropRect in [0, 1] × [0, 1]', () {
      final crop = heuristic.pickCrop(
        imageWidth: 1920,
        imageHeight: 1080,
        detections: [det(left: 800, top: 300, width: 300, height: 500)],
      );
      expect(crop, isNotNull);
      expect(crop!.left, inInclusiveRange(0.0, 1.0));
      expect(crop.top, inInclusiveRange(0.0, 1.0));
      expect(crop.right, inInclusiveRange(0.0, 1.0));
      expect(crop.bottom, inInclusiveRange(0.0, 1.0));
      expect(crop.right, greaterThan(crop.left));
      expect(crop.bottom, greaterThan(crop.top));
    });

    test('Phase XVI.4: default padding gives breathing room around bbox',
        () {
      // Square subject → snaps to 1:1 aspect → final crop width /
      // height both grow by at least (1 + bboxPaddingFraction).
      const imgW = 1000;
      const imgH = 1000;
      final subject = det(left: 400, top: 400, width: 200, height: 200);
      final crop = heuristic.pickCrop(
        imageWidth: imgW,
        imageHeight: imgH,
        detections: [subject],
      );
      expect(crop, isNotNull);
      final cropWpx = crop!.width * imgW;
      final cropHpx = crop.height * imgH;
      // 18 % default padding → 200 × 1.18 = 236. Allow a tiny
      // rounding slack.
      expect(cropWpx, greaterThanOrEqualTo(230));
      expect(cropHpx, greaterThanOrEqualTo(230));
    });

    test('zero padding preserves the tight pre-XVI.4 behaviour', () {
      const heuristicTight = SmartCropHeuristic(bboxPaddingFraction: 0.0);
      const imgW = 1000;
      const imgH = 1000;
      final crop = heuristicTight.pickCrop(
        imageWidth: imgW,
        imageHeight: imgH,
        detections: [det(left: 400, top: 400, width: 200, height: 200)],
      );
      expect(crop, isNotNull);
      final cropWpx = crop!.width * imgW;
      // No padding, square → 200 × 200, exactly (within 1 px).
      expect(cropWpx, closeTo(200, 2));
    });

    test('expanded rect always contains the subject bbox', () {
      // After snap + expand the detection must remain fully inside.
      const imgW = 1920;
      const imgH = 1080;
      final subject = det(left: 700, top: 300, width: 300, height: 500);
      final crop = heuristic.pickCrop(
        imageWidth: imgW,
        imageHeight: imgH,
        detections: [subject],
      );
      expect(crop, isNotNull);
      final cropLeftPx = crop!.left * imgW;
      final cropTopPx = crop.top * imgH;
      final cropRightPx = crop.right * imgW;
      final cropBottomPx = crop.bottom * imgH;
      expect(cropLeftPx, lessThanOrEqualTo(subject.bbox.left + 1));
      expect(cropTopPx, lessThanOrEqualTo(subject.bbox.top + 1));
      expect(cropRightPx, greaterThanOrEqualTo(subject.bbox.right - 1));
      expect(cropBottomPx, greaterThanOrEqualTo(subject.bbox.bottom - 1));
    });
  });
}
