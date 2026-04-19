import 'package:flutter_test/flutter_test.dart';

import 'package:image_editor/features/scanner/domain/models/scan_models.dart';

ScanPage _basePage() => ScanPage(id: 'p1', rawImagePath: '/tmp/p1.jpg');

void main() {
  group('ScanPage adjustments', () {
    test('default values are identity (zero on every knob)', () {
      final p = _basePage();
      expect(p.brightness, 0);
      expect(p.contrast, 0);
      expect(p.thresholdOffset, 0);
    });

    test('copyWith mutates each adjustment independently', () {
      final p = _basePage().copyWith(
        brightness: 0.4,
        contrast: -0.2,
        thresholdOffset: 12,
      );
      expect(p.brightness, 0.4);
      expect(p.contrast, -0.2);
      expect(p.thresholdOffset, 12);
    });

    test('JSON roundtrip preserves non-zero adjustments', () {
      final original = _basePage().copyWith(
        brightness: 0.3,
        contrast: -0.5,
        thresholdOffset: -8,
      );
      final json = original.toJson();
      // Identity values are intentionally omitted from the JSON to
      // keep the persisted file small for the common case.
      expect(json['brightness'], 0.3);
      expect(json['contrast'], -0.5);
      expect(json['thresholdOffset'], -8);

      final restored = ScanPage.fromJson(json);
      expect(restored.brightness, 0.3);
      expect(restored.contrast, -0.5);
      expect(restored.thresholdOffset, -8);
    });

    test('JSON roundtrip omits identity values + decodes them as zero',
        () {
      final json = _basePage().toJson();
      expect(json.containsKey('brightness'), isFalse);
      expect(json.containsKey('contrast'), isFalse);
      expect(json.containsKey('thresholdOffset'), isFalse);
      final restored = ScanPage.fromJson(json);
      expect(restored.brightness, 0);
      expect(restored.contrast, 0);
      expect(restored.thresholdOffset, 0);
    });

    test('legacy JSON without the adjustment keys decodes to identity',
        () {
      final legacyJson = {
        'id': 'p1',
        'raw': '/tmp/p1.jpg',
        'processed': null,
        'corners': Corners.inset().toJson(),
        'filter': 'auto',
        'rot': 0,
        'ocr': null,
      };
      final p = ScanPage.fromJson(legacyJson);
      expect(p.brightness, 0);
      expect(p.contrast, 0);
      expect(p.thresholdOffset, 0);
    });
  });
}
