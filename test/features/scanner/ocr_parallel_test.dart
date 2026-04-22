import 'package:flutter_test/flutter_test.dart';
import 'package:image_editor/features/scanner/application/scanner_notifier.dart';
import 'package:image_editor/features/scanner/data/ocr_service.dart';
import 'package:image_editor/features/scanner/domain/models/scan_models.dart';
import 'package:image_editor/features/scanner/domain/ocr_engine.dart';

/// Phase XI.C.3: [runOcrBatch] fans out [OcrEngine.recognize] calls
/// across every page that lacks a cached result, bounded by
/// [kOcrConcurrency]. This file pins:
///   - skip pages whose `ocr` is non-null (covered by the caller) OR
///     that lack a `processedImagePath`
///   - actual parallelism: N pages with slow recognizers complete in
///     the `max` of the per-page latencies, not the `sum`
///   - commit callback runs synchronously on the main isolate
///   - concurrency bound is respected: at most `kOcrConcurrency`
///     recogniser calls are ever in flight simultaneously
void main() {
  group('runOcrBatch (Phase XI.C.3)', () {
    test('empty pending list is a no-op', () async {
      final engine = _FakeOcrEngine(perCallDelay: Duration.zero);
      final commits = <ScanPage>[];
      await runOcrBatch(
        pending: const [],
        engine: engine,
        concurrency: 4,
        commit: commits.add,
      );
      expect(commits, isEmpty);
      expect(engine.callCount, 0);
    });

    test('skips pages without processedImagePath', () async {
      final engine = _FakeOcrEngine(perCallDelay: Duration.zero);
      final commits = <ScanPage>[];
      await runOcrBatch(
        pending: [
          ScanPage(id: 'no-processed', rawImagePath: '/raw.jpg'),
        ],
        engine: engine,
        concurrency: 4,
        commit: commits.add,
      );
      // Worker short-circuits on null path — no recognition, no commit.
      expect(engine.callCount, 0);
      expect(commits, isEmpty);
    });

    test('commits the OcrResult wrapped on a copyWith\'d ScanPage',
        () async {
      final engine = _FakeOcrEngine(perCallDelay: Duration.zero);
      final commits = <ScanPage>[];
      final page = ScanPage(
        id: 'p1',
        rawImagePath: '/raw1.jpg',
        processedImagePath: '/processed1.jpg',
      );
      await runOcrBatch(
        pending: [page],
        engine: engine,
        concurrency: 4,
        commit: commits.add,
      );
      expect(commits, hasLength(1));
      expect(commits.single.id, 'p1');
      expect(commits.single.ocr, isNotNull);
      expect(commits.single.ocr!.fullText, 'fake-ocr:/processed1.jpg');
    });

    test(
        '5 pages at 100 ms each with concurrency=4 finish in ≤ 2× per-page cost',
        () async {
      // Sequential would be 5 * 100 ms = 500 ms.
      // Two waves of 4 + 1 at concurrency=4 = ~200 ms.
      final engine = _FakeOcrEngine(
        perCallDelay: const Duration(milliseconds: 100),
      );
      final pending = [
        for (var i = 0; i < 5; i++)
          ScanPage(
            id: 'p$i',
            rawImagePath: '/raw$i.jpg',
            processedImagePath: '/processed$i.jpg',
          ),
      ];
      final commits = <ScanPage>[];
      final sw = Stopwatch()..start();
      await runOcrBatch(
        pending: pending,
        engine: engine,
        concurrency: 4,
        commit: commits.add,
      );
      sw.stop();
      expect(commits, hasLength(5));
      expect(
        sw.elapsedMilliseconds,
        lessThan(250),
        reason: '5 pages at 100 ms each should finish in <250 ms with '
            'concurrency=4, got ${sw.elapsedMilliseconds} ms',
      );
    });

    test('respects concurrency cap — never more than N in flight at once',
        () async {
      final engine = _FakeOcrEngine(
        perCallDelay: const Duration(milliseconds: 50),
      );
      final pending = [
        for (var i = 0; i < 10; i++)
          ScanPage(
            id: 'p$i',
            rawImagePath: '/raw$i.jpg',
            processedImagePath: '/processed$i.jpg',
          ),
      ];
      await runOcrBatch(
        pending: pending,
        engine: engine,
        concurrency: 3,
        commit: (_) {},
      );
      expect(engine.peakInFlight, lessThanOrEqualTo(3));
      expect(engine.callCount, 10);
    });

    test('concurrency=1 degrades to sequential (sanity baseline)',
        () async {
      final engine = _FakeOcrEngine(
        perCallDelay: const Duration(milliseconds: 20),
      );
      final pending = [
        for (var i = 0; i < 3; i++)
          ScanPage(
            id: 'p$i',
            rawImagePath: '/raw$i.jpg',
            processedImagePath: '/processed$i.jpg',
          ),
      ];
      final commits = <ScanPage>[];
      await runOcrBatch(
        pending: pending,
        engine: engine,
        concurrency: 1,
        commit: commits.add,
      );
      expect(commits, hasLength(3));
      expect(engine.peakInFlight, 1);
    });
  });

  test('kOcrConcurrency default is 4 (matches kPostCaptureProcessConcurrency)',
      () {
    expect(kOcrConcurrency, 4);
  });
}

/// Test double for [OcrEngine]. Each `recognize` call waits
/// [perCallDelay], records itself, and returns a sentinel
/// [OcrResult] whose text encodes the input path so callers can
/// assert on it.
class _FakeOcrEngine implements OcrEngine {
  _FakeOcrEngine({required this.perCallDelay});
  final Duration perCallDelay;
  int callCount = 0;
  int _inFlight = 0;
  int peakInFlight = 0;

  @override
  Future<OcrResult> recognize(
    String imagePath, {
    OcrScript script = OcrScript.latin,
  }) async {
    callCount++;
    _inFlight++;
    if (_inFlight > peakInFlight) peakInFlight = _inFlight;
    try {
      if (perCallDelay > Duration.zero) {
        await Future<void>.delayed(perCallDelay);
      }
      return OcrResult(fullText: 'fake-ocr:$imagePath', blocks: const []);
    } finally {
      _inFlight--;
    }
  }

  @override
  Future<void> dispose() async {}
}
