import 'dart:math' as math;

/// Shape of a per-layer mask. Phase 8 supports three simple shapes;
/// brush-painted and AI-generated masks land in a later phase.
enum MaskShape { none, linear, radial }

extension MaskShapeX on MaskShape {
  String get label {
    switch (this) {
      case MaskShape.none:
        return 'None';
      case MaskShape.linear:
        return 'Linear';
      case MaskShape.radial:
        return 'Radial';
    }
  }

  static MaskShape fromName(String? name) {
    if (name == null) return MaskShape.none;
    for (final s in MaskShape.values) {
      if (s.name == name) return s;
    }
    return MaskShape.none;
  }
}

/// Procedural mask attached to a content layer. Defines where the layer
/// is visible by interpolating a gradient across the canvas.
///
/// - [MaskShape.none]    — full coverage (identity)
/// - [MaskShape.linear]  — gradient from [cx], [cy] along [angle] in radians
/// - [MaskShape.radial]  — gradient from center [cx], [cy] between
///                         [innerRadius] and [outerRadius] (as fractions
///                         of the canvas min-dimension)
///
/// [feather] softens the transition for both shapes. [inverted] flips
/// visible and hidden regions.
class LayerMask {
  const LayerMask({
    required this.shape,
    this.inverted = false,
    this.feather = 0.2,
    this.cx = 0.5,
    this.cy = 0.5,
    this.angle = 0.0,
    this.innerRadius = 0.2,
    this.outerRadius = 0.6,
  });

  final MaskShape shape;
  final bool inverted;
  final double feather;
  final double cx;
  final double cy;
  final double angle;
  final double innerRadius;
  final double outerRadius;

  static const LayerMask none = LayerMask(shape: MaskShape.none);

  bool get isIdentity => shape == MaskShape.none;

  LayerMask copyWith({
    MaskShape? shape,
    bool? inverted,
    double? feather,
    double? cx,
    double? cy,
    double? angle,
    double? innerRadius,
    double? outerRadius,
  }) {
    return LayerMask(
      shape: shape ?? this.shape,
      inverted: inverted ?? this.inverted,
      feather: feather ?? this.feather,
      cx: cx ?? this.cx,
      cy: cy ?? this.cy,
      angle: angle ?? this.angle,
      innerRadius: innerRadius ?? this.innerRadius,
      outerRadius: outerRadius ?? this.outerRadius,
    );
  }

  Map<String, dynamic> toJson() => {
        'shape': shape.name,
        if (inverted) 'inverted': inverted,
        'feather': feather,
        'cx': cx,
        'cy': cy,
        if (shape == MaskShape.linear) 'angle': angle,
        if (shape == MaskShape.radial) 'innerRadius': innerRadius,
        if (shape == MaskShape.radial) 'outerRadius': outerRadius,
      };

  static LayerMask fromJson(Map<String, dynamic>? json) {
    if (json == null) return LayerMask.none;
    final shape = MaskShapeX.fromName(json['shape'] as String?);
    if (shape == MaskShape.none) return LayerMask.none;
    double numParam(String key, double fallback) {
      final raw = json[key];
      if (raw is num) return raw.toDouble();
      return fallback;
    }

    return LayerMask(
      shape: shape,
      inverted: (json['inverted'] as bool?) ?? false,
      feather: numParam('feather', 0.2),
      cx: numParam('cx', 0.5),
      cy: numParam('cy', 0.5),
      angle: numParam('angle', 0.0),
      innerRadius: numParam('innerRadius', 0.2),
      outerRadius: numParam('outerRadius', 0.6),
    );
  }

  /// Return the two endpoints of the visible→hidden gradient for a
  /// [MaskShape.linear] mask, in the canvas's (0..1, 0..1) space.
  (({double x, double y}) start, ({double x, double y}) end) linearEndpoints() {
    // The line passes through (cx, cy) with direction (cos, sin).
    // Start point is "center - half-length along direction", end is "+".
    final dx = math.cos(angle);
    final dy = math.sin(angle);
    // Half-length scaled by 1 + feather so the transition fits the feather zone.
    final halfLen = 0.5 * (1 + feather.clamp(0.0, 1.0));
    return (
      (x: cx - dx * halfLen, y: cy - dy * halfLen),
      (x: cx + dx * halfLen, y: cy + dy * halfLen),
    );
  }
}
