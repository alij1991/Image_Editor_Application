import 'dart:math' as math;
import 'dart:ui' show Rect;

/// Normalized crop rectangle in source-image coordinate space (each
/// edge is in [0..1] of the source's pre-rotation width/height).
/// `null` means "no crop applied yet — show the full image". An
/// instance with `(0, 0, 1, 1)` is also a no-op and treated the same
/// as `null` by the renderer.
class CropRect {
  const CropRect({
    required this.left,
    required this.top,
    required this.right,
    required this.bottom,
  });

  /// The full-image rect — equivalent to no crop. Useful as the
  /// initial value when the user opens the crop overlay.
  static const CropRect full = CropRect(left: 0, top: 0, right: 1, bottom: 1);

  final double left;
  final double top;
  final double right;
  final double bottom;

  double get width => right - left;
  double get height => bottom - top;

  bool get isFull =>
      left <= 1e-4 && top <= 1e-4 && right >= 1 - 1e-4 && bottom >= 1 - 1e-4;

  Rect toRect(int sourceWidth, int sourceHeight) => Rect.fromLTRB(
        left * sourceWidth,
        top * sourceHeight,
        right * sourceWidth,
        bottom * sourceHeight,
      );

  /// Clamp every edge to [0..1] and ensure right > left, bottom > top.
  CropRect normalized() {
    final l = left.clamp(0.0, 1.0);
    final t = top.clamp(0.0, 1.0);
    final r = right.clamp(0.0, 1.0);
    final b = bottom.clamp(0.0, 1.0);
    return CropRect(
      left: math.min(l, r),
      top: math.min(t, b),
      right: math.max(l, r),
      bottom: math.max(t, b),
    );
  }

  Map<String, double> toParams() => {
        'left': left,
        'top': top,
        'right': right,
        'bottom': bottom,
      };

  static CropRect? fromParams(Map<String, dynamic> params) {
    final l = params['left'];
    final t = params['top'];
    final r = params['right'];
    final b = params['bottom'];
    if (l is! num || t is! num || r is! num || b is! num) return null;
    return CropRect(
      left: l.toDouble(),
      top: t.toDouble(),
      right: r.toDouble(),
      bottom: b.toDouble(),
    ).normalized();
  }

  @override
  bool operator ==(Object other) =>
      other is CropRect &&
      other.left == left &&
      other.top == top &&
      other.right == right &&
      other.bottom == bottom;

  @override
  int get hashCode => Object.hash(left, top, right, bottom);

  @override
  String toString() =>
      'CropRect(${left.toStringAsFixed(2)}, ${top.toStringAsFixed(2)}, '
      '${right.toStringAsFixed(2)}, ${bottom.toStringAsFixed(2)})';
}

/// Immutable geometry transform derived from the geometry ops in an
/// [EditPipeline]. The canvas applies this to the image before running
/// the shader chain for color ops.
///
/// The flow is:
///   1. [PipelineReaders.geometryState] reads rotate/flip/straighten/
///      crop ops and produces a [GeometryState].
///   2. [EditorSession.rebuildPreview] pushes the state to
///      [PreviewController.geometry] (a [ValueNotifier]) alongside the
///      shader passes.
///   3. [ImageCanvas] subscribes to the notifier and wraps its
///      [CustomPaint] in `RotatedBox` + `Transform.rotate` + scale so
///      the rotated image composes correctly with the shader chain.
class GeometryState {
  const GeometryState({
    this.rotationSteps = 0,
    this.straightenDegrees = 0.0,
    this.flipH = false,
    this.flipV = false,
    this.cropAspectRatio,
    this.cropRect,
  });

  /// 90° steps applied via the rotate-CW / rotate-CCW buttons.
  /// Normalized to [0, 3] on construction via [normalized].
  final int rotationSteps;

  /// Fine rotation from the Straighten slider. Clamped to [-45, 45] by
  /// the caller / spec. Measured in degrees for user-friendliness;
  /// [straightenRadians] converts for rendering.
  final double straightenDegrees;

  final bool flipH;
  final bool flipV;

  /// Desired crop aspect ratio (width / height). `null` = free crop
  /// (no enforcement). Used by the crop-overlay drag handles to
  /// constrain resizing; the actual visible crop is in [cropRect].
  final double? cropAspectRatio;

  /// Concrete crop rectangle in normalized [0..1] coordinates of the
  /// pre-rotation source. `null` or `CropRect.full` means no crop is
  /// applied. The canvas clips to this rect; the export pipeline
  /// extracts the rect at full resolution.
  final CropRect? cropRect;

  /// Convenience: the effective crop rect (full when none set).
  CropRect get effectiveCropRect => cropRect ?? CropRect.full;

  /// True iff a crop has been committed and isn't the full-image rect.
  bool get hasCrop => cropRect != null && !cropRect!.isFull;

  static const GeometryState identity = GeometryState();

  /// Straighten value in radians.
  double get straightenRadians => straightenDegrees * math.pi / 180.0;

  /// Number of 90° turns, always in [0, 3].
  int get rotationStepsNormalized => ((rotationSteps % 4) + 4) % 4;

  /// True if this state is the no-op.
  bool get isIdentity =>
      rotationStepsNormalized == 0 &&
      straightenDegrees == 0 &&
      !flipH &&
      !flipV &&
      cropAspectRatio == null &&
      !hasCrop;

  /// True when rotated 90° or 270° — used by [ImageCanvas] to swap
  /// the effective aspect ratio.
  bool get swapsAspect =>
      rotationStepsNormalized == 1 || rotationStepsNormalized == 3;

  GeometryState copyWith({
    int? rotationSteps,
    double? straightenDegrees,
    bool? flipH,
    bool? flipV,
    Object? cropAspectRatio = _sentinel,
    Object? cropRect = _sentinel,
  }) {
    return GeometryState(
      rotationSteps: rotationSteps ?? this.rotationSteps,
      straightenDegrees: straightenDegrees ?? this.straightenDegrees,
      flipH: flipH ?? this.flipH,
      flipV: flipV ?? this.flipV,
      cropAspectRatio: identical(cropAspectRatio, _sentinel)
          ? this.cropAspectRatio
          : cropAspectRatio as double?,
      cropRect: identical(cropRect, _sentinel)
          ? this.cropRect
          : cropRect as CropRect?,
    );
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is GeometryState &&
        other.rotationStepsNormalized == rotationStepsNormalized &&
        other.straightenDegrees == straightenDegrees &&
        other.flipH == flipH &&
        other.flipV == flipV &&
        other.cropAspectRatio == cropAspectRatio &&
        other.cropRect == cropRect;
  }

  @override
  int get hashCode => Object.hash(
        rotationStepsNormalized,
        straightenDegrees,
        flipH,
        flipV,
        cropAspectRatio,
        cropRect,
      );

  @override
  String toString() => 'GeometryState('
      'rot=$rotationStepsNormalized, '
      'straighten=${straightenDegrees.toStringAsFixed(1)}°, '
      'flipH=$flipH, flipV=$flipV, '
      'crop=${cropAspectRatio?.toStringAsFixed(2) ?? "free"}, '
      'rect=${cropRect ?? "full"})';
}

const Object _sentinel = Object();
