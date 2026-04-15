import 'dart:async';
import 'dart:math' as math;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/logging/app_logger.dart';
import '../data/image_processor.dart';
import '../data/ocr_service.dart';
import '../data/scan_repository.dart';
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
  });

  final ScanSession? session;
  final ScannerCapabilities? capabilities;
  final bool isBusy;
  final String? busyLabel;
  final String? error;

  bool get hasPages => (session?.pages.isNotEmpty ?? false);

  ScannerState copyWith({
    ScanSession? session,
    ScannerCapabilities? capabilities,
    bool? isBusy,
    String? busyLabel,
    String? error,
    bool clearSession = false,
    bool clearError = false,
    bool clearBusyLabel = false,
  }) =>
      ScannerState(
        session: clearSession ? null : (session ?? this.session),
        capabilities: capabilities ?? this.capabilities,
        isBusy: isBusy ?? this.isBusy,
        busyLabel: clearBusyLabel ? null : (busyLabel ?? this.busyLabel),
        error: clearError ? null : (error ?? this.error),
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
  final ClassicalCornerSeed cornerSeed;

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
      state = state.copyWith(
        session: ScanSession(pages: result.pages, strategy: result.strategyUsed),
        isBusy: false,
        clearBusyLabel: true,
      );
      _log.i('capture ok', {
        'strategy': result.strategyUsed.name,
        'pages': result.pages.length,
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
      state = state.copyWith(
        isBusy: false,
        clearBusyLabel: true,
        error: 'Native scanner unavailable on this device. '
            'Try Manual or Auto mode instead.',
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

  /// Auto-deskew the given page by running OCR on it (if not already
  /// done), measuring the dominant text-block angle, and rotating by
  /// the negative of that angle so lines are horizontal. A no-op for
  /// pages with no recognised text.
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
    if (page.ocr == null) {
      state = state.copyWith(isBusy: true, busyLabel: 'Analysing layout…');
      final r = await ocr.recognize(page.processedImagePath!);
      if (!mounted) return;
      page = page.copyWith(ocr: r);
      _replacePage(page);
      state = state.copyWith(isBusy: false, clearBusyLabel: true);
    }
    final angle = _estimateSkewDeg(page.ocr!);
    if (angle.abs() < 0.3) {
      _log.i('deskew: already straight', {'page': pageId, 'angle': angle});
      return;
    }
    _log.i('deskew rotate', {'page': pageId, 'deg': -angle});
    rotatePage(pageId, -angle);
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
