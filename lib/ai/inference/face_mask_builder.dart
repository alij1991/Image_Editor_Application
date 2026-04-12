import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import '../services/face_detect/face_detection_service.dart';

/// Builds a single-channel alpha mask that marks where Phase 9d's
/// portrait-smoothing effect should apply. Each detected face is
/// rendered as a feathered ellipse centered on the bounding box,
/// with optional exclusion holes carved around the eye and mouth
/// landmarks so the sharp features stay crisp when the rest of the
/// face is blurred.
///
/// The output is a flat `Float32List` in `[0, 1]` with row-major
/// `width × height` layout — the same shape [blendMaskIntoRgba]
/// accepts. Kept in pure Dart (no `dart:ui` except the [ui.Rect]
/// input type) so it can run inside an isolate worker and be
/// unit-tested without a Flutter binding.
class FaceMaskBuilder {
  const FaceMaskBuilder._();

  /// Build a mask of shape `[height * width]` floats in `[0, 1]` from
  /// [faces].
  ///
  /// - [feather] controls the width of the soft edge as a fraction
  ///   of the face radius. 0.0 = hard edge, 1.0 = the entire ellipse
  ///   is a gradient. Defaults to 0.35 — enough to hide the seam but
  ///   tight enough that the blur still stays visually anchored to
  ///   the face.
  /// - [eyeRadiusScale] / [mouthRadiusScale] scale the exclusion
  ///   holes relative to the inter-eye distance. Defaults chosen so
  ///   the eyes and a typical lip region stay unblurred without
  ///   nibbling into the cheeks.
  /// - If [faces] is empty the result is an all-zero mask.
  static Float32List build({
    required List<DetectedFace> faces,
    required int width,
    required int height,
    double feather = 0.35,
    double eyeRadiusScale = 0.35,
    double mouthRadiusScale = 0.55,
  }) {
    if (width <= 0 || height <= 0) {
      throw ArgumentError('width and height must be > 0');
    }
    if (feather < 0 || feather > 1) {
      throw ArgumentError('feather must be in [0, 1]');
    }

    final mask = Float32List(width * height);
    if (faces.isEmpty) return mask;

    for (final face in faces) {
      _stampFace(
        mask: mask,
        width: width,
        height: height,
        face: face,
        feather: feather,
        eyeRadiusScale: eyeRadiusScale,
        mouthRadiusScale: mouthRadiusScale,
      );
    }
    return mask;
  }

  // ----- internals ---------------------------------------------------------

  /// Draw a single feathered ellipse into [mask] using additive max
  /// so overlapping faces combine correctly.
  static void _stampFace({
    required Float32List mask,
    required int width,
    required int height,
    required DetectedFace face,
    required double feather,
    required double eyeRadiusScale,
    required double mouthRadiusScale,
  }) {
    final box = face.boundingBox;
    final cx = box.center.dx;
    final cy = box.center.dy;
    // Grow the ellipse slightly so the mask covers a bit more than
    // the raw bounding box — chins and hairlines fall outside the
    // detector's box otherwise. 1.15× is an empirical sweet spot.
    final rx = (box.width * 0.575).clamp(1.0, double.infinity);
    final ry = (box.height * 0.65).clamp(1.0, double.infinity);
    final rMax = math.max(rx, ry);

    // Exclusion zones for eyes + mouth. Radius is derived from the
    // inter-eye distance (if both eyes present) or a fallback of
    // `box.width / 4` so landmark-less faces still carve a hole.
    final leftEye = face.landmarks[FaceLandmark.leftEye];
    final rightEye = face.landmarks[FaceLandmark.rightEye];
    final eyeDist = (leftEye != null && rightEye != null)
        ? (leftEye - rightEye).distance
        : box.width * 0.4;
    final eyeR = eyeDist * eyeRadiusScale;
    final mouthR = eyeDist * mouthRadiusScale;

    final mouthCenter = _mouthCenter(face);

    // Clip the iteration range to the face bounding box with a
    // generous margin for the feather falloff. This keeps O(pixels)
    // linear in face area rather than full image.
    final margin = rMax * (1 + feather);
    final x0 = (cx - rx - margin).clamp(0.0, (width - 1).toDouble()).floor();
    final x1 = (cx + rx + margin).clamp(0.0, (width - 1).toDouble()).ceil();
    final y0 = (cy - ry - margin).clamp(0.0, (height - 1).toDouble()).floor();
    final y1 = (cy + ry + margin).clamp(0.0, (height - 1).toDouble()).ceil();

    for (int y = y0; y <= y1; y++) {
      final dy = y - cy;
      for (int x = x0; x <= x1; x++) {
        final dx = x - cx;
        // Normalized ellipse distance: ==1 on the boundary, <1
        // inside, >1 outside. We map to [0, 1] alpha via a smooth
        // falloff that starts at `1 - feather` and ends at 1.
        final d = math.sqrt((dx * dx) / (rx * rx) + (dy * dy) / (ry * ry));
        double alpha;
        if (d <= 1 - feather) {
          alpha = 1;
        } else if (d >= 1) {
          alpha = 0;
        } else {
          final t = (1 - d) / feather;
          alpha = _smoothstep(t);
        }

        // Carve eye + mouth exclusion using a soft subtract so the
        // transition stays clean.
        if (alpha > 0) {
          if (leftEye != null) {
            alpha *= _subtractSoft(x, y, leftEye, eyeR);
          }
          if (rightEye != null) {
            alpha *= _subtractSoft(x, y, rightEye, eyeR);
          }
          if (mouthCenter != null) {
            alpha *= _subtractSoft(x, y, mouthCenter, mouthR);
          }
        }

        if (alpha <= 0) continue;
        final idx = y * width + x;
        // Max combine so overlapping faces don't over-brighten.
        if (alpha > mask[idx]) mask[idx] = alpha;
      }
    }
  }

  /// Smoothstep on `t ∈ [0, 1]` — C¹-continuous ease-in-out. Used
  /// for the face-edge falloff so the blend looks natural.
  static double _smoothstep(double t) {
    if (t <= 0) return 0;
    if (t >= 1) return 1;
    return t * t * (3 - 2 * t);
  }

  /// Return `0` inside the exclusion disk, `1` outside, with a soft
  /// ramp through `radius/2` to `radius`. Multiplied into the main
  /// alpha to carve a smooth hole.
  static double _subtractSoft(
    int x,
    int y,
    ui.Offset center,
    double radius,
  ) {
    final dx = x - center.dx;
    final dy = y - center.dy;
    final d = math.sqrt(dx * dx + dy * dy);
    if (d >= radius) return 1;
    if (d <= radius * 0.5) return 0;
    final t = (d - radius * 0.5) / (radius * 0.5);
    return _smoothstep(t);
  }

  /// Compute the average mouth position from the available landmarks.
  /// Returns null if no mouth landmark is present.
  static ui.Offset? _mouthCenter(DetectedFace face) {
    double sumX = 0;
    double sumY = 0;
    int n = 0;
    for (final key in const [
      FaceLandmark.leftMouth,
      FaceLandmark.rightMouth,
      FaceLandmark.bottomMouth,
    ]) {
      final p = face.landmarks[key];
      if (p == null) continue;
      sumX += p.dx;
      sumY += p.dy;
      n++;
    }
    if (n == 0) return null;
    return ui.Offset(sumX / n, sumY / n);
  }
}
