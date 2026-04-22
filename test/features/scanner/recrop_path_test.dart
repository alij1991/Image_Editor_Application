import 'package:flutter_test/flutter_test.dart';

import 'package:image_editor/features/scanner/domain/models/scan_models.dart';

/// VIII.5 — recrop path: native pages can drop into the crop page with
/// `Corners.inset()` after `prepareForRecrop`. The notifier method is
/// a thin wrapper around `ScanPage.copyWith(corners: …, clearProcessed:
/// true)`; these tests pin the data-side contract so the crop page's
/// "first un-processed page" landing logic finds the recrop'd page.
void main() {
  ScanPage processedPage() => ScanPage(
        id: 'p1',
        rawImagePath: '/tmp/p1.jpg',
        processedImagePath: '/tmp/p1_processed.jpg',
        corners: Corners.full(),
      );

  test('copyWith(clearProcessed: true) drops processedImagePath', () {
    final p = processedPage();
    expect(p.processedImagePath, isNotNull);
    final next = p.copyWith(corners: Corners.inset(), clearProcessed: true);
    expect(next.processedImagePath, isNull);
  });

  test('Corners.inset() default factory returns 0.05 inset', () {
    final c = Corners.inset();
    expect(c.tl.x, 0.05);
    expect(c.tl.y, 0.05);
    expect(c.tr.x, 0.95);
    expect(c.tr.y, 0.05);
    expect(c.br.x, 0.95);
    expect(c.br.y, 0.95);
    expect(c.bl.x, 0.05);
    expect(c.bl.y, 0.95);
  });

  test('after recrop preparation, the page is the first un-processed', () {
    final pages = <ScanPage>[
      ScanPage(
        id: 'p1',
        rawImagePath: '/tmp/p1.jpg',
        processedImagePath: '/tmp/p1_processed.jpg',
      ),
      ScanPage(
        id: 'p2',
        rawImagePath: '/tmp/p2.jpg',
        processedImagePath: '/tmp/p2_processed.jpg',
      ),
    ];

    // Simulate prepareForRecrop on p1 (idx 0).
    final updated = [
      pages[0].copyWith(corners: Corners.inset(), clearProcessed: true),
      pages[1],
    ];

    final firstUnprocessed = updated.indexWhere(
      (p) => p.processedImagePath == null,
    );
    expect(firstUnprocessed, 0,
        reason: 'crop page picks the freshly-recropped page');
    expect(updated[0].corners.tl.x, 0.05,
        reason: 'corners reset to inset so user has a starting frame');
    expect(updated[1].processedImagePath, isNotNull,
        reason: 'untouched page keeps its processed output');
  });

  test('recrop on a native-strategy page does not touch the raw path', () {
    final p = ScanPage(
      id: 'p1',
      rawImagePath: '/tmp/p1_raw.jpg',
      processedImagePath: '/tmp/p1_native.jpg',
    );
    final next = p.copyWith(corners: Corners.inset(), clearProcessed: true);
    expect(next.rawImagePath, '/tmp/p1_raw.jpg',
        reason: 'rawImagePath survives recrop so user can refine the crop');
  });
}
