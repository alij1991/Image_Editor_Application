import 'package:flutter/material.dart';

import '../../../../core/logging/app_logger.dart';

final _log = AppLogger('Viewport');

/// Pan + pinch-zoom transform applied to the editor preview.
///
/// Backed by a `ValueNotifier<Matrix4>` so the wrapping `Transform`
/// widget repaints via an `AnimatedBuilder` without rebuilding the
/// whole editor tree. Scale is clamped to `[minScale, maxScale]`.
///
/// This controller is updated by [SnapseedGestureLayer] when it sees a
/// two-finger gesture (pointerCount ≥ 2) and consumed by the outer
/// `Transform` widget wrapping the [ImageCanvas].
class ViewportTransformController extends ValueNotifier<Matrix4> {
  ViewportTransformController() : super(Matrix4.identity());

  static const double minScale = 1.0;
  static const double maxScale = 6.0;

  /// Current uniform scale. 1.0 means no zoom.
  double get scale {
    // The matrix is always a pure translate + scale (no rotation), so
    // entry [0][0] is the scale factor.
    return value.storage[0];
  }

  /// Current translation (in viewport pixels).
  Offset get translation =>
      Offset(value.storage[12], value.storage[13]);

  bool get isIdentity =>
      scale == 1.0 && translation == Offset.zero;

  // ---- Gesture integration ----------------------------------------------

  double _startScale = 1.0;
  Offset _startTranslation = Offset.zero;
  Offset _startFocal = Offset.zero;

  /// Snapshot the current transform so incremental pinch deltas can be
  /// composed against it. Call at the beginning of each 2-finger
  /// gesture.
  void beginGesture(Offset focal) {
    _startScale = scale;
    _startTranslation = translation;
    _startFocal = focal;
    _log.d('begin', {
      'scale': _startScale.toStringAsFixed(2),
      'focal': '${focal.dx.toInt()},${focal.dy.toInt()}',
    });
  }

  /// Apply a pinch/pan update derived from a [ScaleUpdateDetails].
  /// Zooming pivots around the gesture's current focal point so the
  /// pixel under the user's fingers stays put.
  void updateGesture({
    required double scaleFactor,
    required Offset focalPoint,
  }) {
    final newScale =
        (_startScale * scaleFactor).clamp(minScale, maxScale).toDouble();
    // Pan contribution: how much the focal point moved since gesture
    // start (2-finger drag).
    final panDelta = focalPoint - _startFocal;
    // Zoom-around-focal: keep the image pixel under the focal point
    // stationary as scale changes. The affine transform is:
    //   p_new = F + s_new/s_old * (p_old - F)
    // For our pure translate+scale matrix this decomposes to a shift
    // that depends on the start focal, start translation, and both
    // scales. Applied once per frame, this reads cleanly as:
    final zoomAnchor = _startFocal;
    final zoomRatio = newScale / _startScale;
    final newTranslation = Offset(
      zoomAnchor.dx +
          (_startTranslation.dx - zoomAnchor.dx) * zoomRatio +
          panDelta.dx,
      zoomAnchor.dy +
          (_startTranslation.dy - zoomAnchor.dy) * zoomRatio +
          panDelta.dy,
    );
    value = Matrix4.identity()
      ..translateByDouble(newTranslation.dx, newTranslation.dy, 0, 1)
      ..scaleByDouble(newScale, newScale, newScale, 1);
  }

  /// Reset to identity (no zoom, no pan). Used by the double-tap
  /// gesture and when the user switches source images.
  void reset() {
    if (isIdentity) return;
    _log.i('reset');
    value = Matrix4.identity();
  }
}
