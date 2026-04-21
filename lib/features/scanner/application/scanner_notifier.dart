import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image/image.dart' as img;

import '../../../core/async/generation_guard.dart';
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
    this.permissionBlockedRequiresSettings = false,
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

  /// True when the most recent capture failed because the OS reported
  /// the camera permission as permanentlyDenied / restricted — the UI
  /// surfaces an "Open Settings" button next to the error message
  /// since the dialog can't be re-shown from inside the app.
  final bool permissionBlockedRequiresSettings;

  bool get hasPages => (session?.pages.isNotEmpty ?? false);

  ScannerState copyWith({
    ScanSession? session,
    ScannerCapabilities? capabilities,
    bool? isBusy,
    String? busyLabel,
    String? error,
    String? notice,
    bool? permissionBlockedRequiresSettings,
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
        permissionBlockedRequiresSettings:
            permissionBlockedRequiresSettings ??
                this.permissionBlockedRequiresSettings,
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

  /// Per-page reprocess request id. Each setFilter / setCorners /
  /// rotatePage call bumps the counter for that page via
  /// [GenerationGuard.begin]; the async `process()` finisher captures
  /// the id at call time and only commits its result when
  /// [GenerationGuard.isLatest] is still true. Drops stale results
  /// when the user taps filters faster than a process() call completes
  /// — a real bug seen in field logs where `filter=magicColor` results
  /// were overwriting freshly-selected `filter=grayscale` previews.
  ///
  /// Shared helper lives at `lib/core/async/generation_guard.dart` —
  /// the same guard semantics back the editor's curve-LUT bake race
  /// and cutout hydrate race, which is what Phase IV.4 consolidated.
  final GenerationGuard<String> _processGen = GenerationGuard<String>();

  /// Undo / redo stacks of session snapshots. Mutations push onto
  /// [_undoStack] before applying; redoing an undone change pushes
  /// the un-done snapshot onto [_redoStack]. Capped at 30 entries
  /// each so a long editing session doesn't grow without bound.
  final List<ScanSession> _undoStack = <ScanSession>[];
  final List<ScanSession> _redoStack = <ScanSession>[];
  static const int _historyDepth = 30;

  bool get canUndo => _undoStack.isNotEmpty;
  bool get canRedo => _redoStack.isNotEmpty;

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
    } on NativeScannerPermissionException catch (e) {
      _log.w('camera permission blocked', {'status': e.status.name});
      state = state.copyWith(
        isBusy: false,
        clearBusyLabel: true,
        // Strip the redundant "Try Auto…" suffix in the requires-
        // settings case — the UI surfaces a dedicated "Open Settings"
        // button instead. Otherwise nudge them toward the Auto path.
        error: e.requiresSettings
            ? e.message
            : '${e.message} Try Auto or Manual mode while the dialog '
                'is dismissed.',
        permissionBlockedRequiresSettings: e.requiresSettings,
      );
      return CaptureOutcome.failed;
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

  /// Wipe transient capture state on app resume.
  ///
  /// Called from the capture page's `WidgetsBindingObserver` when the
  /// app comes back to the foreground — typically after the user
  /// tapped "Open Settings" on the camera-permission banner and
  /// toggled the permission. We clear three things:
  ///
  /// 1. The stale "Camera blocked" error banner (the user may have
  ///    just granted the permission so re-displaying the error is
  ///    misleading).
  /// 2. The `permissionBlockedRequiresSettings` flag for the same
  ///    reason — it drives the "Open Settings" CTA which is no longer
  ///    appropriate.
  /// 3. **Any stuck `isBusy=true`** with its busy label. This is the
  ///    real freeze fix: when the user backgrounds the app
  ///    mid-`startCapture()` (e.g. by tapping "Open Settings" while the
  ///    `Permission.camera.request()` future or the
  ///    `cunning_document_scanner` native VC is still pending), iOS
  ///    sometimes never resolves the future when the app comes back.
  ///    Without resetting `isBusy` the "Start scanning" button stays
  ///    disabled with a spinner forever — looks like the app is frozen
  ///    because every interactive control on the page is gated on
  ///    `!isBusy`. Force-resetting on resume gives the user a clean
  ///    retry path.
  ///
  /// Safe even when the user backgrounded the app intentionally with
  /// no in-flight capture — the no-op early-return covers that case.
  void clearTransientError() {
    final hasError = state.error != null;
    final hasPermFlag = state.permissionBlockedRequiresSettings;
    final stuckBusy = state.isBusy;
    if (!hasError && !hasPermFlag && !stuckBusy) return;
    if (stuckBusy) {
      _log.w('resume recovery: clearing stuck isBusy', {
        'busyLabel': state.busyLabel,
      });
    }
    state = state.copyWith(
      clearError: true,
      permissionBlockedRequiresSettings: false,
      isBusy: false,
      clearBusyLabel: true,
    );
  }

  /// Update a page's corners and trigger a re-process.
  void setCorners(String pageId, Corners corners) {
    final s = state.session;
    if (s == null) return;
    final idx = s.pages.indexWhere((p) => p.id == pageId);
    if (idx < 0) return;
    _snapshotForUndo();
    final updated = s.pages[idx]
        .copyWith(corners: corners, clearProcessed: true);
    _replacePage(updated);
    final gen = _nextProcessGen(pageId);
    _log.d('corners set', {'page': pageId, 'gen': gen});
    unawaited(_renderTwoTier(pageId, updated, gen, label: 'corners'));
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

  /// Per-page brightness / contrast / threshold offset slider. The
  /// debounced commit lives on the UI side — this method commits
  /// immediately so the two-tier render gives instant feedback. The
  /// undo snapshot is taken once per gesture (only if the value
  /// actually changed); rapid drag-frames don't bloat the stack.
  void setPageAdjustment(
    String pageId, {
    double? brightness,
    double? contrast,
    double? thresholdOffset,
  }) {
    final s = state.session;
    if (s == null) return;
    final idx = s.pages.indexWhere((p) => p.id == pageId);
    if (idx < 0) return;
    final page = s.pages[idx];
    final nextBrightness =
        (brightness ?? page.brightness).clamp(-1.0, 1.0);
    final nextContrast = (contrast ?? page.contrast).clamp(-1.0, 1.0);
    final nextThreshold =
        (thresholdOffset ?? page.thresholdOffset).clamp(-30.0, 30.0);
    if (nextBrightness == page.brightness &&
        nextContrast == page.contrast &&
        nextThreshold == page.thresholdOffset) {
      return;
    }
    // Snapshot only on the first frame of a gesture (= when the prev
    // values were all at their identity, OR when this is a coarse
    // commit). The UI triggers `commitPageAdjustment` to insert a
    // discrete history entry on slider release.
    final updated = page.copyWith(
      brightness: nextBrightness,
      contrast: nextContrast,
      thresholdOffset: nextThreshold,
      clearProcessed: true,
    );
    _replacePage(updated);
    final gen = _nextProcessGen(pageId);
    unawaited(_renderTwoTier(pageId, updated, gen, label: 'tune'));
  }

  /// Push a snapshot onto the undo stack representing the state
  /// BEFORE the current Tune gesture started. Called by the UI on
  /// slider drag-start so a single undo restores the pre-gesture
  /// state instead of one drag frame.
  void beginPageAdjustmentGesture() {
    _snapshotForUndo();
  }

  void setFilter(String pageId, ScanFilter filter) {
    final s = state.session;
    if (s == null) return;
    final idx = s.pages.indexWhere((p) => p.id == pageId);
    if (idx < 0) return;
    if (s.pages[idx].filter == filter) return; // no-op tap
    _snapshotForUndo();
    final updated = s.pages[idx]
        .copyWith(filter: filter, clearProcessed: true);
    _replacePage(updated);
    final gen = _nextProcessGen(pageId);
    _log.d('filter set', {'page': pageId, 'filter': filter.name, 'gen': gen});
    unawaited(_renderTwoTier(pageId, updated, gen, label: 'filter'));
  }

  void rotatePage(String pageId, double deltaDeg) {
    final s = state.session;
    if (s == null) return;
    final idx = s.pages.indexWhere((p) => p.id == pageId);
    if (idx < 0) return;
    _snapshotForUndo();
    final page = s.pages[idx];
    final updated = page.copyWith(
      rotationDeg: (page.rotationDeg + deltaDeg) % 360,
      clearProcessed: true,
    );
    _replacePage(updated);
    final gen = _nextProcessGen(pageId);
    _log.d('rotate', {'page': pageId, 'delta': deltaDeg, 'gen': gen});
    unawaited(_renderTwoTier(pageId, updated, gen, label: 'rotate'));
  }

  /// Two-tier render: kick off a 1024-px preview first so the canvas
  /// updates within ~500 ms; then chase with the full-resolution
  /// render so exports / re-ingestion get the proper pixels.
  /// Both honour the [gen] generation stamp — a later mutation can
  /// invalidate either tier and we drop the result rather than
  /// overwriting fresher state. The full-res tier is also gated on
  /// the preview tier still being current at the time it lands so a
  /// rapid filter cycle doesn't keep the slow render running long
  /// past the user's interest.
  Future<void> _renderTwoTier(
    String pageId,
    ScanPage requested,
    int gen, {
    required String label,
  }) async {
    // Tier 1: preview.
    try {
      final preview = await processor.processPreview(requested);
      if (!mounted) return;
      if (!_isLatestProcess(pageId, gen)) {
        _log.d('preview discarded — superseded',
            {'page': pageId, 'gen': gen, 'label': label});
        return;
      }
      _replacePage(preview);
    } catch (e, st) {
      _log.w('preview render failed',
          {'page': pageId, 'label': label, 'err': e.toString()});
      _log.d('preview stack', st);
    }
    // Tier 2: full resolution. Don't bother starting if a newer
    // mutation has already invalidated us during the preview.
    if (!_isLatestProcess(pageId, gen)) return;
    try {
      final full = await processor.process(requested);
      if (!mounted) return;
      if (!_isLatestProcess(pageId, gen)) {
        _log.d('full result discarded — superseded',
            {'page': pageId, 'gen': gen, 'label': label});
        return;
      }
      _replacePage(full);
    } catch (e, st) {
      _log.w('full render failed',
          {'page': pageId, 'label': label, 'err': e.toString()});
      _log.d('full stack', st);
    }
  }

  void removePage(String pageId) {
    final s = state.session;
    if (s == null) return;
    _snapshotForUndo();
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
    _snapshotForUndo();
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

  /// Tear down the current session entirely. Wipes the undo / redo
  /// history too — once the user leaves the scanner there's nothing
  /// meaningful to undo into.
  void clear() {
    _undoStack.clear();
    _redoStack.clear();
    _processGen.clear();
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
      // Snapshot AFTER the picker returns (cancelling a picker
      // shouldn't push an undoable snapshot — it's not a mutation).
      _snapshotForUndo();
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
  ///
  /// Runs OCR on demand if the page doesn't already have it cached —
  /// without text density the classifier was returning `unknown`
  /// almost universally (real bug seen in field logs). The OCR result
  /// is persisted on the page so subsequent classify / deskew /
  /// export passes don't re-run it.
  Future<DocumentType?> classifyPage(String pageId) async {
    final s = state.session;
    if (s == null) return null;
    final idx = s.pages.indexWhere((p) => p.id == pageId);
    if (idx < 0) return null;
    var page = s.pages[idx];
    if (page.processedImagePath == null) return null;
    if (page.ocr == null) {
      state = state.copyWith(isBusy: true, busyLabel: 'Reading text…');
      try {
        final r = await ocr.recognize(page.processedImagePath!);
        if (!mounted) return null;
        page = page.copyWith(ocr: r);
        _replacePage(page);
      } finally {
        if (mounted) {
          state = state.copyWith(isBusy: false, clearBusyLabel: true);
        }
      }
    }
    try {
      final type = await compute(
        _classifyIsolate,
        _ClassifyPayload(path: page.processedImagePath!, ocr: page.ocr),
      );
      _log.i('classify', {
        'page': pageId,
        'type': type.name,
        'ocrChars': page.ocr?.fullText.length ?? 0,
      });
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

  /// Bump the reprocess counter for [pageId] and return the new id.
  /// Caller stores this and passes it to [_isLatestProcess] before
  /// committing the async result. Thin wrapper over
  /// [GenerationGuard.begin] — kept as a private helper so the
  /// existing call sites read the same way they did pre-Phase-IV.4.
  int _nextProcessGen(String pageId) => _processGen.begin(pageId);

  /// True when [gen] is still the latest issued for [pageId]. Async
  /// process() finishers call this before [_replacePage] so stale
  /// results from earlier filter/corner/rotation taps don't overwrite
  /// fresher state. Thin wrapper over [GenerationGuard.isLatest].
  bool _isLatestProcess(String pageId, int gen) =>
      _processGen.isLatest(pageId, gen);

  /// Snapshot the current session onto the undo stack and clear the
  /// redo stack. Called at the START of every undoable mutation
  /// (setFilter, setCorners, rotatePage, removePage, reorderPage,
  /// addMorePages). No-op when there's no session.
  void _snapshotForUndo() {
    final s = state.session;
    if (s == null) return;
    _undoStack.add(s);
    if (_undoStack.length > _historyDepth) _undoStack.removeAt(0);
    if (_redoStack.isNotEmpty) _redoStack.clear();
  }

  /// Pop the last snapshot off the undo stack and restore it. Pushes
  /// the current session onto the redo stack first so [redo] can
  /// reverse the operation.
  void undo() {
    final s = state.session;
    if (s == null || _undoStack.isEmpty) return;
    _redoStack.add(s);
    final restored = _undoStack.removeLast();
    state = state.copyWith(session: restored);
    _log.i('undo', {
      'pages': restored.pages.length,
      'undoLeft': _undoStack.length,
      'redoLeft': _redoStack.length,
    });
  }

  /// Reverse a prior [undo]. Pushes the current session back onto the
  /// undo stack so the user can flip-flop freely.
  void redo() {
    final s = state.session;
    if (s == null || _redoStack.isEmpty) return;
    _undoStack.add(s);
    final restored = _redoStack.removeLast();
    state = state.copyWith(session: restored);
    _log.i('redo', {
      'pages': restored.pages.length,
      'undoLeft': _undoStack.length,
      'redoLeft': _redoStack.length,
    });
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
