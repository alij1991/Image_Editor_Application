import 'dart:math' as math;

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
  /// (no enforcement). Phase 6 ships this as metadata only — the full
  /// crop rectangle drag UI lands in Phase 7/12.
  final double? cropAspectRatio;

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
      cropAspectRatio == null;

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
  }) {
    return GeometryState(
      rotationSteps: rotationSteps ?? this.rotationSteps,
      straightenDegrees: straightenDegrees ?? this.straightenDegrees,
      flipH: flipH ?? this.flipH,
      flipV: flipV ?? this.flipV,
      cropAspectRatio: identical(cropAspectRatio, _sentinel)
          ? this.cropAspectRatio
          : cropAspectRatio as double?,
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
        other.cropAspectRatio == cropAspectRatio;
  }

  @override
  int get hashCode => Object.hash(
        rotationStepsNormalized,
        straightenDegrees,
        flipH,
        flipV,
        cropAspectRatio,
      );

  @override
  String toString() => 'GeometryState('
      'rot=$rotationStepsNormalized, '
      'straighten=${straightenDegrees.toStringAsFixed(1)}°, '
      'flipH=$flipH, flipV=$flipV, '
      'crop=${cropAspectRatio?.toStringAsFixed(2) ?? "free"})';
}

const Object _sentinel = Object();
