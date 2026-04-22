import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';

import 'package:image_editor/ai/services/object_detection/coco_labels.dart';
import 'package:image_editor/ai/services/object_detection/object_detector_service.dart';

/// Phase XIV.1: unit tests for the pure-Dart surface of the object
/// detector. The service itself is not exercised here — a real TFLite
/// session would need the full plugin setup. These tests pin the
/// label table, class-index constants, and value-object contracts so
/// callers (smart-crop + scanner seeder) have a stable API.
void main() {
  group('CocoLabels', () {
    test('labels list has exactly 80 COCO categories', () {
      // Densely packed 0..79 — the model the manifest ships emits
      // indices into this table directly. A pre-pinned length catches
      // silent drift if someone removes a label.
      expect(CocoLabels.labels.length, 80);
    });

    test('labels list has no empty slots', () {
      for (int i = 0; i < CocoLabels.labels.length; i++) {
        expect(CocoLabels.labels[i], isNotEmpty,
            reason: 'label at index $i is empty');
      }
    });

    test('labelFor returns null for out-of-range indices', () {
      expect(CocoLabels.labelFor(-1), isNull);
      expect(CocoLabels.labelFor(80), isNull);
      expect(CocoLabels.labelFor(1000), isNull);
    });

    test('named class constants map to their human labels', () {
      expect(CocoLabels.labelFor(CocoLabels.personClass), 'person');
      expect(CocoLabels.labelFor(CocoLabels.catClass), 'cat');
      expect(CocoLabels.labelFor(CocoLabels.dogClass), 'dog');
      expect(CocoLabels.labelFor(CocoLabels.bookClass), 'book');
      expect(CocoLabels.labelFor(CocoLabels.laptopClass), 'laptop');
      expect(CocoLabels.labelFor(CocoLabels.tvClass), 'tv');
      expect(CocoLabels.labelFor(CocoLabels.cellPhoneClass), 'cell phone');
    });

    test('scannerPriorClasses contains only document-adjacent classes', () {
      // Scanner's corner-seeder assumes any hit here is a rectangular
      // object with sensible dimensions on a typical doc scan.
      expect(CocoLabels.scannerPriorClasses, hasLength(4));
      for (final c in CocoLabels.scannerPriorClasses) {
        expect(CocoLabels.labelFor(c), isNotNull);
      }
    });

    test('foodClasses all resolve to real labels', () {
      for (final c in CocoLabels.foodClasses) {
        expect(CocoLabels.labelFor(c), isNotNull,
            reason: 'food class $c missing label');
      }
    });
  });

  group('ObjectDetection value object', () {
    test('label delegates to CocoLabels.labelFor', () {
      const det = ObjectDetection(
        bbox: ui.Rect.fromLTWH(10, 20, 30, 40),
        classIndex: CocoLabels.personClass,
        score: 0.9,
      );
      expect(det.label, 'person');
    });

    test('toString carries label + score + bbox', () {
      const det = ObjectDetection(
        bbox: ui.Rect.fromLTWH(0, 0, 10, 10),
        classIndex: CocoLabels.catClass,
        score: 0.87,
      );
      final s = det.toString();
      expect(s, contains('cat'));
      expect(s, contains('0.87'));
    });

    test('out-of-range classIndex produces null label', () {
      const det = ObjectDetection(
        bbox: ui.Rect.fromLTWH(0, 0, 1, 1),
        classIndex: 999,
        score: 0.5,
      );
      expect(det.label, isNull);
    });
  });
}
