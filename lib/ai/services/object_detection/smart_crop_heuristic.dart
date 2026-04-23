import 'dart:math' as math;

import '../../../engine/pipeline/geometry_state.dart';
import 'coco_labels.dart';
import 'object_detector_service.dart';

/// Phase XIV.2: pure-Dart policy that turns a list of
/// [ObjectDetection]s into a normalised [CropRect] the editor can
/// apply via `EditorSession.setCropRect`.
///
/// Policy, ordered:
///   1. Filter detections to score ≥ [minScore].
///   2. If any "preferred-subject" class hits (person, pet, food),
///      pick the highest-score one.
///   3. Otherwise pick the highest-score detection of ANY class.
///   4. Snap the chosen bbox to the nearest standard crop aspect
///      (1:1, 4:5, 5:4, 9:16, 16:9). Expanding the short side is
///      always preferred over cropping the long side so no part of
///      the subject leaves the frame.
///   5. Clamp the expanded rect to the source-image bounds.
///
/// Returns null when no acceptable detection exists — callers show
/// a "no subject detected" info snackbar and leave the crop alone.
class SmartCropHeuristic {
  const SmartCropHeuristic({
    this.minScore = 0.5,
    this.candidateAspects = defaultCandidateAspects,
    this.bboxPaddingFraction = 0.18,
  });

  /// Default aspect menu — the five formats that cover most
  /// publishing surfaces (square, portrait 4:5 + 5:4, portrait 9:16
  /// for Stories / TikTok, landscape 16:9 for widescreen). Callers
  /// can override with a different set.
  static const List<double> defaultCandidateAspects = <double>[
    1.0,         // 1:1
    4 / 5,       // 4:5 (portrait, Instagram feed)
    5 / 4,       // 5:4 (landscape, classic print)
    9 / 16,      // 9:16 (portrait, stories / reels)
    16 / 9,      // 16:9 (landscape, widescreen)
  ];

  /// COCO class ids that rank ahead of everything else when choosing
  /// a subject. The order inside the set is irrelevant — we still
  /// pick by score.
  static const Set<int> preferredSubjectClasses = <int>{
    CocoLabels.personClass,
    CocoLabels.catClass,
    CocoLabels.dogClass,
    ...CocoLabels.foodClasses,
  };

  /// Detections below this confidence never drive the crop. A
  /// moderate threshold so blurry / far-away subjects don't force a
  /// terrible crop.
  final double minScore;

  final List<double> candidateAspects;

  /// Phase XVI.4 — how much breathing room to add around the
  /// detected subject before snapping to an aspect. The object
  /// detector's bboxes sit tight on the subject's silhouette;
  /// applying the crop to that bare bbox makes the result feel
  /// cramped (field report on 2026-04-22 — smart-crop output
  /// clipped hair and shoulders). 0.18 (= 18 % of each side
  /// expanded on each edge) matches the industry convention for
  /// auto-crop — enough that the subject breathes but not so much
  /// that the crop becomes a mild zoom.
  final double bboxPaddingFraction;

  /// Run the policy against [detections] over an image of size
  /// [imageWidth] × [imageHeight] (pixels). Returns a normalised
  /// [CropRect] (edges in `[0, 1]`) or null when the policy bails.
  CropRect? pickCrop({
    required int imageWidth,
    required int imageHeight,
    required List<ObjectDetection> detections,
  }) {
    if (imageWidth <= 0 || imageHeight <= 0) return null;

    // Step 1: filter by score. The detector already sorts by
    // descending score, but we can't rely on that contract.
    final good = detections
        .where((d) => d.score >= minScore)
        .toList(growable: false);
    if (good.isEmpty) return null;

    // Step 2: prefer a subject class.
    ObjectDetection? best;
    for (final d in good) {
      if (preferredSubjectClasses.contains(d.classIndex)) {
        if (best == null || d.score > best.score) {
          best = d;
        }
      }
    }

    // Step 3: fall back to top-scored across all classes.
    best ??= good.reduce((a, b) => a.score >= b.score ? a : b);

    // Step 4: snap to the closest-aspect crop that CONTAINS the
    // detection bbox. Expanding only — we never clip the subject.
    //
    // Phase XVI.4 — add [bboxPaddingFraction] breathing room before
    // the aspect snap so the subject isn't crammed against every
    // edge of the crop. The padded bbox has the same aspect as the
    // original (symmetric padding) so the aspect-snap decision
    // doesn't shift; only the final crop rect grows.
    final bb = best.bbox;
    final bbAspect = bb.width / bb.height;
    double closest = candidateAspects.first;
    double closestDelta = (math.log(closest) - math.log(bbAspect)).abs();
    for (final a in candidateAspects.skip(1)) {
      final delta = (math.log(a) - math.log(bbAspect)).abs();
      if (delta < closestDelta) {
        closest = a;
        closestDelta = delta;
      }
    }

    // Enforce the aspect by expanding the short side about the bbox
    // centre. Clamp to image bounds. If hard bounds prevent the
    // target aspect, shrink toward the bound (i.e. the final rect
    // respects the image but best-effort matches the aspect).
    final centreX = (bb.left + bb.right) / 2;
    final centreY = (bb.top + bb.bottom) / 2;

    final paddingScale = 1.0 + bboxPaddingFraction;
    double targetW = bb.width * paddingScale;
    double targetH = bb.height * paddingScale;
    // closest = w/h → if we expand height we get a portrait; if we
    // expand width we get a landscape. Expand whichever direction
    // keeps both dimensions ≥ the bbox's corresponding dimension.
    if (targetW / targetH > closest) {
      // bbox is wider than target → expand height.
      targetH = targetW / closest;
    } else {
      // bbox is taller than target → expand width.
      targetW = targetH * closest;
    }

    double left = centreX - targetW / 2;
    double top = centreY - targetH / 2;
    double right = centreX + targetW / 2;
    double bottom = centreY + targetH / 2;

    // Step 5: push the rect inside the image bounds by sliding
    // (keeps width/height) and if that fails, clamp + accept aspect
    // degradation.
    if (left < 0) {
      right -= left;
      left = 0;
    }
    if (top < 0) {
      bottom -= top;
      top = 0;
    }
    if (right > imageWidth) {
      final over = right - imageWidth;
      left = math.max(0.0, left - over);
      right = imageWidth.toDouble();
    }
    if (bottom > imageHeight) {
      final over = bottom - imageHeight;
      top = math.max(0.0, top - over);
      bottom = imageHeight.toDouble();
    }
    // Final clamp in case both slides still overshot (rare: subject
    // bbox is already larger than image in that axis).
    left = left.clamp(0.0, imageWidth.toDouble());
    top = top.clamp(0.0, imageHeight.toDouble());
    right = right.clamp(0.0, imageWidth.toDouble());
    bottom = bottom.clamp(0.0, imageHeight.toDouble());

    // Guard against degenerate results (zero-area, or basically the
    // full frame — don't bother applying a crop that does nothing).
    final w = right - left;
    final h = bottom - top;
    if (w < 2 || h < 2) return null;
    if (w / imageWidth >= 0.98 && h / imageHeight >= 0.98) return null;

    return CropRect(
      left: left / imageWidth,
      top: top / imageHeight,
      right: right / imageWidth,
      bottom: bottom / imageHeight,
    ).normalized();
  }
}
