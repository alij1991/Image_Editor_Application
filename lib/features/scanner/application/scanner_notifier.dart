import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image/image.dart' as img;

import '../../../core/logging/app_logger.dart';
import '../data/auto_rotate.dart';
import '../data/image_processor.dart';
import '../data/image_stats_extractor.dart';
import '../data/ocr_service.dart';
import '../data/scan_repository.dart';
import '../domain/document_classifier.dart';
import '../domain/document_detector.dart';
import '../domain/models/scan_models.dart';
import '../infrastructure/capabilities_probe.dart';
import '../infrastructure/classical_corner_seed.dart';
import '../infrastructure/image_picker_capture.dart';
import '../infrastructure/manual_document_detector.dart';
import '../infrastructure/native_document_detector.dart';

final _log = AppLogger('ScannerState');

/// Immutable state of the scanner flow.
class ScannerState {
  const ScannerState({
    this.session,
    this.capabilities,
    this.isBusy = false,
    this.busyLabel,
    this.error,
    this.notice,
  });

  final ScanSession? session;
  final ScannerCapabilities? capabilities;
  final bool isBusy;
  final String? busyLabel;
  final String? error;

  /// Non-blocking informational coaching shown on the crop / review
  /// pages (e.g. "Auto detection couldn't find page edges — drag the
  /// corners to fit your page"). Lower-severity than [error].
  final String? notice;

  bool get hasPages => (session?.pages.isNotEmpty ?? false);

  ScannerState copyWith({
    ScanSession? session,
    ScannerCapabilities? capabilities,
    bool? isBusy,
    String? busyLabel,
    String? error,
    String? notice,
    bool clearSession = false,
    bool clearError = false,
    bool clearBusyLabel = false,
    bool clearNotice = false,
  }) =>
      ScannerState(
        session: clearSession ? null : (session ?? this.session),
        capabilities: capabilities ?? this.capabilities,
        isBusy: isBusy ?? this.isBusy,
        busyLabel: clearBusyLabel ? null : (busyLabel ?? this.busyLabel),
        error: clearError ? null : (error ?? this.error),
        notice: clearNotice ? null : (notice ?? this.notice),
      );
}

/// Central state holder for the scanner flow. One session at a time;
/// the user starts a new one by tapping "Scan" on the home page.
class ScannerNotifier extends StateNotifier<ScannerState> {
  ScannerNotifier({
    required this.probe,
    required this.processor,
    required this.ocr,
    required this.repository,
    required this.picker,
    required this.cornerSeed,
  }) : super(const ScannerState()) {
    _warmProbe();
  }

  final CapabilitiesProbe probe;
  final ScanImageProcessor processor;
  final OcrService ocr;
  final ScanRepository repository;
  final ImagePickerCapture picker;
  final CornerSeeder cornerSeed;

  Future<void> _warmProbe() async {
    final caps = await probe.probe();
    if (!mounted) return;
    state = state.copyWith(capabilities: caps);
  }

  DetectorStrategy get recommendedStrategy =>
      state.capabilities?.recommended ?? DetectorStrategy.manual;

  /// Launch a capture flow. Returns a [CaptureOutcome] telling the UI
  /// which screen to jump to next (review or crop) or whether the user
  /// cancelled.
  Future<CaptureOutcome> startCapture(
    DetectorStrategy strategy, {
    ManualPickSource pickSource = ManualPickSource.askUser,
  }) async {
    _log.i('capture start', {'strategy': strategy.name, 'src': pickSource.name});
    state = state.copyWith(
      isBusy: true,
      busyLabel: 'Opening scanner…',
      clearError: true,
    );
    try {
      final detector = _detectorFor(strategy, pickSource);
      final result = await detector.capture();
      // Build a coaching notice when the Auto heuristic bottomed out
      // on one or more pages — keeps the user from staring at a
      // full-frame quad wondering what went wrong.
      final notice = coachingNoticeFor(result);
      state = state.copyWith(
        session: ScanSession(pages: result.pages, strategy: result.strategyUsed),
        isBusy: false,
        clearBusyLabel: true,
        notice: notice,
        clearNotice: notice == null,
      );
      _log.i('capture ok', {
        'strategy': result.strategyUsed.name,
        'pages': result.pages.length,
        'fellBack': result.autoFellBackCount,
      });
      // Native path produces already-cropped images: process straight
      // to thumbnails and skip the crop page. Manual/Auto need the
      // user to accept corners first.
      if (result.strategyUsed == DetectorStrategy.native) {
        unawaited(_processAllPages());
        return CaptureOutcome.gotoReview;
      }
      return CaptureOutcome.gotoCrop;
    } on ScannerCancelledException {
      _log.d('capture cancelled');
      state = state.copyWith(isBusy: false, clearBusyLabel: true);
      return CaptureOutcome.cancelled;
    } on ScannerUnavailableException catch (e) {
      _log.w('capture unavailable', {'err': e.reason});
      // Prefer the probe's specific reason (e.g. "Play Services
      // disabled") over the generic detector message. Always tell the
      // user which alternative to try.
      final probeReason = state.capabilities?.nativeUnavailableReason;
      state = state.copyWith(
        isBusy: false,
        clearBusyLabel: true,
        error: '${probeReason ?? "Native scanner unavailable on this device."} '
            'Try Auto or Manual mode instead.',
      );
      return CaptureOutcome.failed;
    } catch (e, st) {
      _log.e('capture failed', error: e, stackTrace: st);
      state = state.copyWith(
        isBusy: false,
        clearBusyLabel: true,
        error: 'Capture failed: $e',
      );
      return CaptureOutcome.failed;
    }
  }

  DocumentDetector _detectorFor(
    DetectorStrategy strategy,
    ManualPickSource pickSource,
  ) {
    switch (strategy) {
      case DetectorStrategy.native:
        return const NativeDocumentDetector();
      case DetectorStrategy.manual:
        return ManualDocumentDetector(
          picker: picker,
          seeder: cornerSeed,
          useAutoSeed: false,
          pickSource: pickSource,
        );
      case DetectorStrategy.auto:
        return ManualDocumentDetector(
          picker: picker,
          seeder: cornerSeed,
          useAutoSeed: true,
          pickSource: pickSource,
        );
    }
  }

  /// Translate a [DetectionResult] into a coaching string the crop
  /// page can show as a banner. Returns null when the detection went
  /// cleanly (every page got real auto corners, or strategy isn't
  /// Auto). Public+static so tests can exercise the messaging matrix
  /// without booting the full notifier.
  static String? coachingNoticeFor(DetectionResult result) {
    if (result.strategyUsed != DetectorStrategy.auto) return null;
    final n = result.autoFellBackCount;
    if (n <= 0) return null;
    if (result.pages.length == 1) {
      return "Couldn't detect page edges automatically — drag the "
          'corners to fit your page.';
    }
    return "Couldn't detect edges on $n of ${result.pages.length} pages "
        '— drag the corners on those to fit your page.';
  }

  /// Dismiss the current coaching notice (banner close button).
  void dismissNotice() {
    if (state.notice == null) return;
    state = state.copyWith(clearNotice: true);
  }

  /// Update a page's corners and trigger a re-process.
  void setCorners(String pageId, Corners corners) {
    final s = state.session;
    if (s == null) return;
    final idx = s.pages.indexWhere((p) => p.id == pageId);
    if (idx < 0) return;
    final updated = s.pages[idx]
        .copyWith(corners: corners, clearProcessed: true);
    _replacePage(updated);
    _log.d('corners set', {'page': pageId});
    unawaited(() async {
      final processed = await processor.process(updated);
      if (!mounted) return;
      _replacePage(processed);
    }());
  }

  Future<void> _processAllPages() async {
    final s = state.session;
    if (s == null) return;
    for (var i = 0; i < s.pages.length; i++) {
      final page = s.pages[i];
      if (page.processedImagePath != null) continue;
      final processed = await processor.process(page);
      if (!mounted) return;
      _replacePage(processed);
    }
  }

  void setFilter(String pageId, ScanFilter filter) {
    final s = state.session;
    if (s == null) return;
    final idx = s.pages.indexWhere((p) => p.id == pageId);
    if (idx < 0) return;
    final updated = s.pages[idx]
        .copyWith(filter: filter, clearProcessed: true);
    _replacePage(updated);
    _log.d('filter set', {'page': pageId, 'filter': filter.name});
    // Re-process this page only.
    unawaited(() async {
      final processed = await processor.process(updated);
      if (!mounted) return;
      _replacePage(processed);
    }());
  }

  void rotatePage(String pageId, double deltaDeg) {
    final s = state.session;
    if (s == null) return;
    final idx = s.pages.indexWhere((p) => p.id == pageId);
    if (idx < 0) return;
    final page = s.pages[idx];
    final updated = page.copyWith(
      rotationDeg: (page.rotationDeg + deltaDeg) % 360,
      clearProcessed: true,
    );
    _replacePage(updated);
    _log.d('rotate', {'page': pageId, 'delta': deltaDeg});
    unawaited(() async {
      final processed = await processor.process(updated);
      if (!mounted) return;
      _replacePage(processed);
    }());
  }

  void removePage(String pageId) {
    final s = state.session;
    if (s == null) return;
    final pages = s.pages.where((p) => p.id != pageId).toList(growable: false);
    state = state.copyWith(
      session: s.copyWith(pages: pages),
    );
    _log.i('remove page', {'page': pageId, 'remaining': pages.length});
  }

  void reorderPage(int oldIndex, int newIndex) {
    final s = state.session;
    if (s == null) return;
    final list = List<ScanPage>.from(s.pages);
    if (oldIndex < 0 || oldIndex >= list.length) return;
    final item = list.removeAt(oldIndex);
    final dest = newIndex > oldIndex ? newIndex - 1 : newIndex;
    list.insert(dest.clamp(0, list.length), item);
    state = state.copyWith(session: s.copyWith(pages: list));
    _log.d('reorder', {'from': oldIndex, 'to': newIndex});
  }

  void setTitle(String? title) {
    final s = state.session;
    if (s == null) return;
    state = state.copyWith(session: s.copyWith(title: title));
  }

  void clear() {
    state = state.copyWith(clearSession: true, clearError: true);
    _log.i('cleared');
  }

  /// Append additional page(s) to the current session by re-running
  /// the same detector strategy that built it. Lets the user keep
  /// adding pages from the review screen instead of restarting the
  /// whole capture flow. Returns a [CaptureOutcome] describing the
  /// next screen — `gotoCrop` for Manual/Auto (the new pages need
  /// corner editing), or `gotoReview` for Native (returned pre-cropped).
  Future<CaptureOutcome> addMorePages({
    ManualPickSource pickSource = ManualPickSource.askUser,
  }) async {
    final s = state.session;
    if (s == null) {
      _log.w('addMorePages with no session');
      return CaptureOutcome.failed;
    }
    final strategy = s.strategy;
    _log.i('add more pages', {'strategy': strategy.name});
    state = state.copyWith(
      isBusy: true,
      busyLabel: 'Adding more pages…',
      clearError: true,
    );
    try {
      final detector = _detectorFor(strategy, pickSource);
      final result = await detector.capture();
      // Append the freshly captured pages to the existing session.
      final mergedPages = [...s.pages, ...result.pages];
      final notice = coachingNoticeFor(result);
      state = state.copyWith(
        session: s.copyWith(pages: mergedPages),
        isBusy: false,
        clearBusyLabel: true,
        notice: notice,
        clearNotice: notice == null,
      );
      _log.i('added pages', {
        'new': result.pages.length,
        'total': mergedPages.length,
      });
      // Native pages are already cropped — kick off processing for the
      // new entries straight away. Manual/Auto need the user to crop
      // the new pages before processing fires (the crop page handles
      // both old + new in order, but the existing pages are already
      // processed so the user steps through new ones only — the page
      // model exposes `processedImagePath` as a "is processed" flag).
      if (strategy == DetectorStrategy.native) {
        unawaited(_processAllPages());
        return CaptureOutcome.gotoReview;
      }
      return CaptureOutcome.gotoCrop;
    } on ScannerCancelledException {
      state = state.copyWith(isBusy: false, clearBusyLabel: true);
      return CaptureOutcome.cancelled;
    } catch (e, st) {
      _log.e('addMorePages failed', error: e, stackTrace: st);
      state = state.copyWith(
        isBusy: false,
        clearBusyLabel: true,
        error: 'Failed to add pages: $e',
      );
      return CaptureOutcome.failed;
    }
  }

  /// Load an existing session from the repository back into the editor
  /// so the user can re-export it.
  void loadSession(ScanSession session) {
    state = state.copyWith(session: session, clearError: true);
    _log.i('loaded', {'id': session.id, 'pages': session.pages.length});
  }

  /// Persist the current session so it shows up in the History tab.
  Future<void> persistCurrent() async {
    final s = state.session;
    if (s == null) return;
    await repository.save(s);
  }

  /// Auto-deskew the given page. Tries an image-based OpenCV
  /// (Canny + probabilistic Hough) estimation first because it works
  /// on text-less pages and doesn't require a 1–2 s ML Kit OCR pass.
  /// Falls back to the OCR-derived baseline angle when Hough yields
  /// nothing — the prior text-block heuristic remains a safety net for
  /// images where the native OpenCV library is unavailable (test
  /// runner) or the page has only sparse line edges.
  Future<void> autoDeskewPage(String pageId) async {
    final s = state.session;
    if (s == null) return;
    final idx = s.pages.indexWhere((p) => p.id == pageId);
    if (idx < 0) return;
    var page = s.pages[idx];
    if (page.processedImagePath == null) {
      _log.w('deskew skipped; no processed image yet', {'page': pageId});
      return;
    }

    // Image-based path: cheap, no model load, works on photos and
    // text-less drawings.
    state = state.copyWith(isBusy: true, busyLabel: 'Estimating skew…');
    final imgAngle = await _estimateImageSkew(page.processedImagePath!);
    if (!mounted) return;
    state = state.copyWith(isBusy: false, clearBusyLabel: true);

    double? angle = imgAngle;
    if (angle == null) {
      // OCR-based fallback for when Hough didn't find enough lines.
      if (page.ocr == null) {
        state = state.copyWith(isBusy: true, busyLabel: 'Analysing layout…');
        final r = await ocr.recognize(page.processedImagePath!);
        if (!mounted) return;
        page = page.copyWith(ocr: r);
        _replacePage(page);
        state = state.copyWith(isBusy: false, clearBusyLabel: true);
      }
      angle = _estimateSkewDeg(page.ocr!);
    }
    if (angle.abs() < 0.3) {
      _log.i('deskew: already straight', {'page': pageId, 'angle': angle});
      return;
    }
    _log.i('deskew rotate',
        {'page': pageId, 'deg': -angle, 'src': imgAngle != null ? 'cv' : 'ocr'});
    rotatePage(pageId, -angle);
  }

  /// Run [estimateDeskewDegrees] off the UI thread. Returns null when
  /// OpenCV can't load (test runner) or when too few lines survived
  /// the Hough filter to be confident.
  Future<double?> _estimateImageSkew(String path) async {
    try {
      return await compute(_estimateSkewIsolate, path);
    } catch (e, st) {
      _log.w('skew isolate failed', {'err': e.toString()});
      _log.d('stack', st);
      return null;
    }
  }

  /// Detect a sideways page and rotate it 90° clockwise so the text
  /// runs horizontally. Uses [estimateRotationDegrees] (Canny + Hough)
  /// — a no-op when the heuristic isn't confident or OpenCV isn't
  /// loaded. The user can hit "Rotate" again from the review page if
  /// the page was actually 270° / 180° instead of 90°.
  Future<void> autoRotatePage(String pageId) async {
    final s = state.session;
    if (s == null) return;
    final idx = s.pages.indexWhere((p) => p.id == pageId);
    if (idx < 0) return;
    final page = s.pages[idx];
    if (page.processedImagePath == null) {
      _log.w('auto-rotate skipped; no processed image yet', {'page': pageId});
      return;
    }
    state = state.copyWith(isBusy: true, busyLabel: 'Detecting orientation…');
    final rot = await _estimateImageRotation(page.processedImagePath!);
    if (!mounted) return;
    state = state.copyWith(isBusy: false, clearBusyLabel: true);
    if (rot == null || rot == 0) {
      _log.i('auto-rotate: already upright', {'page': pageId});
      return;
    }
    _log.i('auto-rotate', {'page': pageId, 'deg': rot});
    rotatePage(pageId, rot.toDouble());
  }

  Future<int?> _estimateImageRotation(String path) async {
    try {
      return await compute(_estimateRotationIsolate, path);
    } catch (e, st) {
      _log.w('rotation isolate failed', {'err': e.toString()});
      _log.d('stack', st);
      return null;
    }
  }

  /// Run the heuristic [DocumentClassifier] on a processed page and
  /// return the suggested filter. Caller can apply it via [setFilter]
  /// or surface it in the UI as a one-tap suggestion. Returns null
  /// when the page hasn't been processed yet, or [DocumentType.unknown]
  /// when no rule fired (the UI should treat that as "no suggestion").
  Future<DocumentType?> classifyPage(String pageId) async {
    final s = state.session;
    if (s == null) return null;
    final idx = s.pages.indexWhere((p) => p.id == pageId);
    if (idx < 0) return null;
    final page = s.pages[idx];
    if (page.processedImagePath == null) return null;
    try {
      final type = await compute(
        _classifyIsolate,
        _ClassifyPayload(path: page.processedImagePath!, ocr: page.ocr),
      );
      _log.i('classify', {'page': pageId, 'type': type.name});
      return type;
    } catch (e, st) {
      _log.w('classify isolate failed', {'err': e.toString()});
      _log.d('stack', st);
      return null;
    }
  }

  double _estimateSkewDeg(OcrResult ocr) {
    if (ocr.blocks.isEmpty) return 0;
    // Median of per-block aspect-ratio-derived angles — robust against
    // a single mis-detected block. Each block's angle is approximated
    // from width/height of its bounding box (ML Kit returns axis-
    // aligned boxes, so small skew shows up as taller-than-expected
    // boxes; we use the top edge of consecutive blocks to infer a
    // baseline slope).
    final angles = <double>[];
    final sorted = [...ocr.blocks]..sort((a, b) => a.top.compareTo(b.top));
    for (var i = 1; i < sorted.length; i++) {
      final a = sorted[i - 1];
      final b = sorted[i];
      final dy = b.top - a.top;
      final dx = (b.left + b.width / 2) - (a.left + a.width / 2);
      if (dx.abs() < 4) continue;
      final deg = math.atan2(dy, dx) * 180 / math.pi;
      // Text lines should be nearly horizontal; ignore outliers.
      if (deg.abs() > 25) continue;
      angles.add(deg);
    }
    if (angles.isEmpty) return 0;
    angles.sort();
    return angles[angles.length ~/ 2];
  }

  /// Run OCR on every page that doesn't have a cached result yet.
  /// Safe to call repeatedly; no-ops on already-OCR'd pages.
  Future<void> runOcrIfMissing() async {
    final s = state.session;
    if (s == null) return;
    for (final page in s.pages) {
      if (page.ocr != null) continue;
      final path = page.processedImagePath;
      if (path == null) continue;
      state = state.copyWith(
        isBusy: true,
        busyLabel: 'Recognising text…',
      );
      final r = await ocr.recognize(path);
      if (!mounted) return;
      _replacePage(page.copyWith(ocr: r));
    }
    state = state.copyWith(isBusy: false, clearBusyLabel: true);
    _log.i('ocr pass done');
  }

  void _replacePage(ScanPage page) {
    final s = state.session;
    if (s == null) return;
    final list = [
      for (final p in s.pages) if (p.id == page.id) page else p,
    ];
    state = state.copyWith(session: s.copyWith(pages: list));
  }
}

/// What the capture page should do after `startCapture` returns.
enum CaptureOutcome {
  gotoReview,
  gotoCrop,
  cancelled,
  failed,
}

/// Top-level isolate entry: decodes the JPEG at [path] and runs the
/// OpenCV-backed Hough deskew estimator. Top-level so `compute()` can
/// hand it across the isolate boundary.
double? _estimateSkewIsolate(String path) {
  final bytes = File(path).readAsBytesSync();
  final decoded = img.decodeImage(bytes);
  if (decoded == null) return null;
  return estimateDeskewDegrees(decoded);
}

int? _estimateRotationIsolate(String path) {
  final bytes = File(path).readAsBytesSync();
  final decoded = img.decodeImage(bytes);
  if (decoded == null) return null;
  return estimateRotationDegrees(decoded);
}

class _ClassifyPayload {
  const _ClassifyPayload({required this.path, required this.ocr});
  final String path;
  final OcrResult? ocr;
}

DocumentType _classifyIsolate(_ClassifyPayload payload) {
  final bytes = File(payload.path).readAsBytesSync();
  final decoded = img.decodeImage(bytes);
  if (decoded == null) return DocumentType.unknown;
  final stats = computeImageStats(decoded);
  return const DocumentClassifier().classify(stats: stats, ocr: payload.ocr);
}
