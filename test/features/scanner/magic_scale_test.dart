import 'package:flutter_test/flutter_test.dart';

import 'package:image_editor/features/scanner/domain/models/scan_models.dart';

/// VIII.19 — per-page Magic-Color intensity slider. The slider maps
/// straight to `ScanPage.magicScale` which the image processor
/// forwards to `magicColorWithOpenCv(scale: …)`. These tests pin the
/// data-side contract (default, range, JSON round-trip).
void main() {
  ScanPage base() => ScanPage(id: 'p1', rawImagePath: '/tmp/p1.jpg');

  test('default magicScale is 220 (matches the legacy hard-coded value)',
      () {
    expect(base().magicScale, 220);
  });

  test('copyWith updates magicScale independently', () {
    final p = base().copyWith(magicScale: 200);
    expect(p.magicScale, 200);
    expect(p.brightness, 0);
    expect(p.contrast, 0);
  });

  test('JSON omits magicScale when at default 220', () {
    final json = base().toJson();
    expect(json.containsKey('magicScale'), isFalse);
  });

  test('JSON round-trip preserves a non-default magicScale', () {
    final original = base().copyWith(magicScale: 195);
    final restored = ScanPage.fromJson(original.toJson());
    expect(restored.magicScale, 195);
  });

  test('legacy JSON without magicScale decodes to 220', () {
    final legacy = {
      'id': 'p1',
      'raw': '/tmp/p1.jpg',
      'corners': Corners.inset().toJson(),
      'filter': 'magicColor',
      'rot': 0,
    };
    final p = ScanPage.fromJson(legacy);
    expect(p.magicScale, 220);
  });
}
