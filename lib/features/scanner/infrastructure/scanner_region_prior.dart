import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import '../../../ai/services/object_detection/coco_labels.dart';
import '../../../ai/services/object_detection/object_detector_service.dart';
import '../../../core/logging/app_logger.dart';

final _log = AppLogger('ScannerRegionPrior');

/// Phase XIV.3: optional pre-pass that narrows the scanner's
/// corner-finding search to a confident region instead of the whole
/// frame. Helps on cluttered tabletops where the paper sits among
/// book stacks / mugs / laptops — the OpenCV contour finder
/// otherwise picks up the laptop edge as "the best quad" when the
/// page itself has soft borders.
///
/// The interface returns a normalised rectangle (all four edges in
/// `[0, 1]`) or null to signal "no useful prior — search the whole
/// frame". Keeping it normalised decouples the prior from the
/// corner-seeder's internal downscale resolution.
abstract class ScannerRegionPrior {
  const ScannerRegionPrior();

  /// Return a normalised region-of-interest for [imagePath] or null
  /// when the prior has nothing to contribute.
  Future<ScannerRegion?> findRegion(String imagePath);

  /// Release any owned native resources (model sessions etc.). Safe
  /// to call multiple times — implementations must be idempotent.
  Future<void> close();
}

/// Value object so callers don't have to depend on `dart:ui.Rect` and
/// so the `left/top/right/bottom` contract is explicit.
class ScannerRegion {
  const ScannerRegion({
    required this.left,
    required this.top,
    required this.right,
    required this.bottom,
  });

  /// All four edges are in the normalised `[0, 1]` domain of the
  /// source image.
  final double left;
  final double top;
  final double right;
  final double bottom;

  double get width => right - left;
  double get height => bottom - top;

  @override
  String toString() => 'ScannerRegion(L${left.toStringAsFixed(2)}, '
      'T${top.toStringAsFixed(2)}, R${right.toStringAsFixed(2)}, '
      'B${bottom.toStringAsFixed(2)})';
}

/// A [ScannerRegionPrior] that runs EfficientDet-Lite0 and returns
/// the bbox of the highest-scoring document-adjacent class
/// (book / laptop / tv / cell phone). Below [minScore] it returns
/// null; that maps back to the default full-frame search.
///
/// The service is passed in from outside so the provider layer owns
/// the lifetime and can reuse one detector across multiple seed
/// calls in a multi-page session without paying the LiteRT load cost
/// per page.
class ObjectDetectorRegionPrior extends ScannerRegionPrior {
  ObjectDetectorRegionPrior({
    required this.detector,
    this.minScore = 0.5,
    this.paddingFraction = 0.08,
  });

  /// The already-loaded detector. Ownership is passed in — callers
  /// are responsible for closing via [close] when the scanner session
  /// ends.
  final ObjectDetectorService detector;

  /// Minimum score a document-adjacent class must reach to be used
  /// as a prior. Too low → false positives (a coffee cup mistaken
  /// for a laptop) shrinks the search into the wrong region.
  final double minScore;

  /// Fraction of the bbox's width / height padded on each side before
  /// the prior is returned. The detector's bounding boxes are tight
  /// on the object — paper corners typically extend a few percent
  /// beyond the book / laptop bbox, so some slack protects the
  /// corner finder from cropping the page.
  final double paddingFraction;

  bool _closed = false;

  @override
  Future<ScannerRegion?> findRegion(String imagePath) async {
    if (_closed) return null;
    try {
      final decoded = await _decodeForDetection(imagePath);
      final detections = await detector.runOnRgba(
        sourceRgba: decoded.bytes,
        sourceWidth: decoded.width,
        sourceHeight: decoded.height,
      );
      if (detections.isEmpty) {
        _log.d('no detections for region prior');
        return null;
      }

      // Filter to document-adjacent classes above the confidence
      // threshold, then pick the highest-scored.
      ObjectDetection? best;
      for (final d in detections) {
        if (!CocoLabels.scannerPriorClasses.contains(d.classIndex)) continue;
        if (d.score < minScore) continue;
        if (best == null || d.score > best.score) best = d;
      }
      if (best == null) {
        _log.d('no document-adjacent class hit — no prior');
        return null;
      }

      // Pad + normalise. Clamping to [0, 1] after adding padding so
      // a near-border bbox doesn't poke outside the image.
      final bb = best.bbox;
      final padX = bb.width * paddingFraction;
      final padY = bb.height * paddingFraction;
      final left = ((bb.left - padX) / decoded.width).clamp(0.0, 1.0);
      final top = ((bb.top - padY) / decoded.height).clamp(0.0, 1.0);
      final right = ((bb.right + padX) / decoded.width).clamp(0.0, 1.0);
      final bottom = ((bb.bottom + padY) / decoded.height).clamp(0.0, 1.0);
      final region = ScannerRegion(
        left: left,
        top: top,
        right: right,
        bottom: bottom,
      );
      _log.i('region prior hit', {
        'class': best.label ?? best.classIndex,
        'score': best.score.toStringAsFixed(2),
        'region': region.toString(),
      });
      return region;
    } catch (e, st) {
      _log.w('region prior failed — falling through', {'err': e.toString()});
      _log.d('stack', st);
      return null;
    }
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    try {
      await detector.close();
    } catch (_) {
      // best-effort
    }
  }

  /// Decode [imagePath] into an RGBA buffer sized for object
  /// detection. 1024 px long edge is plenty for COCO detection at
  /// 320 × 320 input (the service rescales anyway); anything larger
  /// is wasted I/O + memory.
  Future<_DecodedFrame> _decodeForDetection(String path) async {
    const maxEdge = 1024;
    final bytes = await File(path).readAsBytes();
    final fullCodec = await ui.instantiateImageCodec(bytes);
    final probeFrame = await fullCodec.getNextFrame();
    final fullW = probeFrame.image.width;
    final fullH = probeFrame.image.height;
    probeFrame.image.dispose();
    fullCodec.dispose();

    int? targetW;
    int? targetH;
    final longest = fullW > fullH ? fullW : fullH;
    if (longest > maxEdge) {
      final scale = maxEdge / longest;
      targetW = (fullW * scale).round();
      targetH = (fullH * scale).round();
    }

    final codec = await ui.instantiateImageCodec(
      bytes,
      targetWidth: targetW,
      targetHeight: targetH,
    );
    final frame = await codec.getNextFrame();
    codec.dispose();
    final image = frame.image;
    try {
      final bd = await image.toByteData(
        format: ui.ImageByteFormat.rawStraightRgba,
      );
      if (bd == null) {
        throw StateError('toByteData returned null');
      }
      return _DecodedFrame(
        bytes: bd.buffer.asUint8List(),
        width: image.width,
        height: image.height,
      );
    } finally {
      image.dispose();
    }
  }
}

class _DecodedFrame {
  const _DecodedFrame({
    required this.bytes,
    required this.width,
    required this.height,
  });

  final Uint8List bytes;
  final int width;
  final int height;
}
