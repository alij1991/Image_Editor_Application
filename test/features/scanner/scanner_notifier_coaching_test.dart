import 'package:flutter_test/flutter_test.dart';

import 'package:image_editor/features/scanner/application/scanner_notifier.dart';
import 'package:image_editor/features/scanner/domain/document_detector.dart';
import 'package:image_editor/features/scanner/domain/models/scan_models.dart';

ScanPage _page(String id) =>
    ScanPage(id: id, rawImagePath: '/tmp/$id.jpg');

void main() {
  group('ScannerNotifier.coachingNoticeFor', () {
    test('returns null for the native strategy regardless of fallback count',
        () {
      const result = DetectionResult(
        pages: [],
        strategyUsed: DetectorStrategy.native,
        autoFellBackCount: 99,
      );
      expect(ScannerNotifier.coachingNoticeFor(result), isNull);
    });

    test('returns null for the manual strategy', () {
      final result = DetectionResult(
        pages: [_page('a')],
        strategyUsed: DetectorStrategy.manual,
      );
      expect(ScannerNotifier.coachingNoticeFor(result), isNull);
    });

    test('returns null when auto succeeded on every page', () {
      final result = DetectionResult(
        pages: [_page('a'), _page('b')],
        strategyUsed: DetectorStrategy.auto,
      );
      expect(ScannerNotifier.coachingNoticeFor(result), isNull);
    });

    test('uses singular phrasing on the only-page-fell-back case', () {
      final result = DetectionResult(
        pages: [_page('a')],
        strategyUsed: DetectorStrategy.auto,
        autoFellBackCount: 1,
      );
      final notice = ScannerNotifier.coachingNoticeFor(result);
      expect(notice, isNotNull);
      expect(notice, contains('drag'));
      expect(notice, isNot(contains('of 1 pages')));
    });

    test('reports the n / total ratio on partial fallback', () {
      final result = DetectionResult(
        pages: [_page('a'), _page('b'), _page('c')],
        strategyUsed: DetectorStrategy.auto,
        autoFellBackCount: 2,
      );
      final notice = ScannerNotifier.coachingNoticeFor(result);
      expect(notice, contains('2 of 3 pages'));
    });
  });
}
