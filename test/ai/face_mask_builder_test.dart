import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';

import 'package:image_editor/ai/inference/face_mask_builder.dart';
import 'package:image_editor/ai/services/face_detect/face_detection_service.dart';

DetectedFace _face({
  required double x,
  required double y,
  required double w,
  required double h,
  Map<FaceLandmark, ui.Offset>? landmarks,
}) {
  return DetectedFace(
    boundingBox: ui.Rect.fromLTWH(x, y, w, h),
    landmarks: landmarks ?? const {},
    headEulerAngleZ: 0.0,
  );
}

void main() {
  group('FaceMaskBuilder.build — validation', () {
    test('rejects non-positive dimensions', () {
      expect(
        () => FaceMaskBuilder.build(
          faces: const [],
          width: 0,
          height: 10,
        ),
        throwsArgumentError,
      );
      expect(
        () => FaceMaskBuilder.build(
          faces: const [],
          width: 10,
          height: -1,
        ),
        throwsArgumentError,
      );
    });

    test('rejects out-of-range feather', () {
      expect(
        () => FaceMaskBuilder.build(
          faces: const [],
          width: 10,
          height: 10,
          feather: -0.1,
        ),
        throwsArgumentError,
      );
      expect(
        () => FaceMaskBuilder.build(
          faces: const [],
          width: 10,
          height: 10,
          feather: 1.5,
        ),
        throwsArgumentError,
      );
    });
  });

  group('FaceMaskBuilder.build — empty + sanity', () {
    test('empty face list → all-zero mask of correct length', () {
      final mask = FaceMaskBuilder.build(
        faces: const [],
        width: 8,
        height: 4,
      );
      expect(mask.length, 32);
      expect(mask.every((v) => v == 0), true);
    });

    test('one face draws a non-zero region', () {
      final face = _face(x: 30, y: 30, w: 40, h: 40);
      final mask = FaceMaskBuilder.build(
        faces: [face],
        width: 100,
        height: 100,
      );
      expect(mask.length, 10000);
      // The bounding box center should be ≈1.0 (inside the
      // hard-alpha core).
      const cx = 50;
      const cy = 50;
      expect(mask[cy * 100 + cx], greaterThan(0.9));
      // A pixel far outside should be 0.
      expect(mask[5 * 100 + 5], 0);
      expect(mask[95 * 100 + 95], 0);
    });

    test('faces outside the image bounds clip cleanly', () {
      // Face mostly above the image — only the bottom strip overlaps.
      final face = _face(x: 10, y: -50, w: 60, h: 100);
      final mask = FaceMaskBuilder.build(
        faces: [face],
        width: 80,
        height: 80,
      );
      // Top-left of the image should still get some alpha because
      // the face extends into the top portion.
      expect(mask.any((v) => v > 0), true);
      // The far bottom row should be untouched.
      var bottomNonZero = 0;
      for (int x = 0; x < 80; x++) {
        if (mask[79 * 80 + x] > 0) bottomNonZero++;
      }
      expect(bottomNonZero, 0,
          reason: 'face center is way above the image');
    });
  });

  group('FaceMaskBuilder.build — landmark exclusion', () {
    test('eye landmark carves a hole inside the face mask', () {
      const eyeCenter = ui.Offset(50, 45);
      final faceWith = _face(
        x: 30,
        y: 30,
        w: 40,
        h: 40,
        landmarks: {
          FaceLandmark.leftEye: eyeCenter,
          FaceLandmark.rightEye: const ui.Offset(60, 45),
        },
      );
      final faceWithout = _face(x: 30, y: 30, w: 40, h: 40);
      final maskWith = FaceMaskBuilder.build(
        faces: [faceWith],
        width: 100,
        height: 100,
      );
      final maskWithout = FaceMaskBuilder.build(
        faces: [faceWithout],
        width: 100,
        height: 100,
      );
      // The pixel at the eye position should be lower (carved out)
      // when the eye landmark is provided.
      const at = 50 + (45 * 100);
      expect(maskWith[at], lessThan(maskWithout[at]));
    });
  });

  group('FaceMaskBuilder.build — overlap', () {
    test('overlapping faces use max combine, not additive', () {
      final faceA = _face(x: 30, y: 30, w: 40, h: 40);
      final faceB = _face(x: 40, y: 40, w: 40, h: 40);
      final mask = FaceMaskBuilder.build(
        faces: [faceA, faceB],
        width: 100,
        height: 100,
      );
      // Find the global max — must not exceed 1.0.
      double globalMax = 0;
      for (final v in mask) {
        if (v > globalMax) globalMax = v;
      }
      expect(globalMax, lessThanOrEqualTo(1.0));
      expect(globalMax, greaterThan(0.9),
          reason: 'overlapping cores should still hit ≈1.0');
    });
  });
}
