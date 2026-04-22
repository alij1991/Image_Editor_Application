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

    // VIII.14 — when the detector reports which specific pages fell
    // back, the banner names them instead of a bare ratio.
    test('singular page reference uses "page N" wording', () {
      final result = DetectionResult(
        pages: [_page('a'), _page('b'), _page('c')],
        strategyUsed: DetectorStrategy.auto,
        autoFellBackCount: 1,
        autoFellBackPages: [2],
      );
      final notice = ScannerNotifier.coachingNoticeFor(result);
      expect(notice, contains('on page 2'));
      expect(notice, isNot(contains('1 of 3 pages')));
    });

    test('two-page fallback uses "pages X and Y" wording', () {
      final result = DetectionResult(
        pages: [_page('a'), _page('b'), _page('c')],
        strategyUsed: DetectorStrategy.auto,
        autoFellBackCount: 2,
        autoFellBackPages: [1, 3],
      );
      final notice = ScannerNotifier.coachingNoticeFor(result);
      expect(notice, contains('pages 1 and 3'));
    });

    test('three-page fallback uses Oxford-comma joiner', () {
      final result = DetectionResult(
        pages: [_page('a'), _page('b'), _page('c'), _page('d')],
        strategyUsed: DetectorStrategy.auto,
        autoFellBackCount: 3,
        autoFellBackPages: [1, 2, 4],
      );
      final notice = ScannerNotifier.coachingNoticeFor(result);
      expect(notice, contains('pages 1, 2 and 4'));
    });

    test('legacy ratio wording survives when autoFellBackPages is empty',
        () {
      final result = DetectionResult(
        pages: [_page('a'), _page('b')],
        strategyUsed: DetectorStrategy.auto,
        autoFellBackCount: 1,
      );
      final notice = ScannerNotifier.coachingNoticeFor(result);
      // Falls through to the n/total form; the new specific wording
      // requires the page-indexes channel to be populated.
      expect(notice, contains('1 of 2 pages'));
    });
  });
}
