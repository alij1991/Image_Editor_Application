import 'dart:math' as math;
import 'dart:ui' as ui;

import '../pipeline/geometry_state.dart';

/// Phase XVI.38 — pure-Dart math that picks a smart crop centred on a
/// face when one is available, otherwise centred on the image. The
/// caller (GeometryPanel) feeds in the cached faces from
/// `FaceDetectionCache.tryGetCached` and the desired aspect; this
/// returns a normalised [CropRect] the editor can apply via
/// `EditorSession.setCropRect`.
///
/// Sibling to [SmartCropHeuristic] in `ai/services/object_detection`,
/// which handles the heavier object-detector path. They share the
/// "expand to aspect, slide inside bounds" math but differ in their
/// subject-picking policy (faces here, COCO-class detections there).
class SmartCropPlacer {
  const SmartCropPlacer({
    this.facePaddingFraction = 0.6,
  });

  /// XVI.38 — how much breathing room to add around the largest face
  /// before snapping to the requested aspect. Faces are typically
  /// ~30% of the frame; padding 60% of each side (so the face becomes
  /// ~1/4 of the crop area) keeps the subject centred without
  /// cropping the head/shoulders.
  final double facePaddingFraction;

  /// Standard aspects the smart-crop UI offers. Square (Instagram),
  /// 4:5 (Instagram portrait), 16:9 (widescreen / landscape).
  static const double aspectSquare = 1.0;
  static const double aspectPortrait45 = 4 / 5;
  static const double aspectLandscape169 = 16 / 9;

  /// Compute a [CropRect] for an image of [imageWidth]×[imageHeight]
  /// pixels at the given [aspect] (width/height ratio). When [faces]
  /// is non-null and non-empty, the crop centres on the largest face
  /// (by area); otherwise it centres on the image. The returned rect
  /// is always normalised to `[0, 1]`.
  ///
  /// Returns null when the image dimensions are degenerate (≤ 0) or
  /// when the resulting crop would essentially be the full frame
  /// (>= 98% on both axes — applying it would be a no-op).
  CropRect? suggest({
    required int imageWidth,
    required int imageHeight,
    required double aspect,
    List<ui.Rect>? faces,
  }) {
    if (imageWidth <= 0 || imageHeight <= 0) return null;
    if (aspect <= 0) return null;

    // Centre point + initial half-size. With a face, we anchor on
    // the face centre and start from a face-bbox-derived size; with
    // no face, we anchor on the image centre and start from the
    // full image size (the aspect snap will then crop to fit).
    final ui.Rect? largest = _largestFace(faces);

    final double centreX;
    final double centreY;
    double targetW;
    double targetH;

    if (largest != null) {
      centreX = largest.left + largest.width / 2;
      centreY = largest.top + largest.height / 2;
      // Pad the face so the crop has subject breathing room. Then
      // grow whichever dimension needs more pixels to satisfy the
      // requested aspect, so the face is never clipped.
      final paddingScale = 1.0 + facePaddingFraction;
      targetW = largest.width * paddingScale;
      targetH = largest.height * paddingScale;
    } else {
      // No face — start from the full image and let the aspect snap
      // crop the appropriate axis. This is the "centre on image"
      // fallback (a brightness-centroid pivot is a future polish).
      centreX = imageWidth / 2;
      centreY = imageHeight / 2;
      targetW = imageWidth.toDouble();
      targetH = imageHeight.toDouble();
    }

    // Apply the aspect by expanding (face path) or contracting (no-
    // face path) the appropriate dimension. The face path always
    // grows because the bbox is smaller than the image; the no-face
    // path starts at full image size, so the dimension already at
    // the bound contracts via the aspect snap below.
    if (largest != null) {
      if (targetW / targetH > aspect) {
        // Bbox is wider than target → grow height.
        targetH = targetW / aspect;
      } else {
        // Bbox is taller than target → grow width.
        targetW = targetH * aspect;
      }
    } else {
      // No-face path: take the aspect of the image and shrink the
      // larger dimension so the result fits inside the image.
      final imgAspect = imageWidth / imageHeight;
      if (aspect > imgAspect) {
        // Target is wider than image → keep width, contract height.
        targetH = targetW / aspect;
      } else {
        targetW = targetH * aspect;
      }
    }

    double left = centreX - targetW / 2;
    double top = centreY - targetH / 2;
    double right = centreX + targetW / 2;
    double bottom = centreY + targetH / 2;

    // Slide the rect into bounds without changing its size (so the
    // aspect stays exact). When sliding alone can't fit the rect
    // (subject is outside the image, or the rect is bigger than the
    // image), we accept clamping and a slight aspect drift.
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
    left = left.clamp(0.0, imageWidth.toDouble());
    top = top.clamp(0.0, imageHeight.toDouble());
    right = right.clamp(0.0, imageWidth.toDouble());
    bottom = bottom.clamp(0.0, imageHeight.toDouble());

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

  /// Largest face by area, or null when the list is null/empty/all-
  /// zero-area.
  ui.Rect? _largestFace(List<ui.Rect>? faces) {
    if (faces == null || faces.isEmpty) return null;
    ui.Rect? best;
    double bestArea = 0;
    for (final r in faces) {
      final a = r.width * r.height;
      if (a > bestArea) {
        bestArea = a;
        best = r;
      }
    }
    if (best == null || bestArea <= 0) return null;
    return best;
  }
}
