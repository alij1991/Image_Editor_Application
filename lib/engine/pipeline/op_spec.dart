import 'edit_op_type.dart';

/// Metadata for a single adjustable parameter.
///
/// A Phase 4 scalar op (e.g. brightness) has exactly one [OpSpec]. A
/// multi-parameter op (e.g. vignette: amount + feather + roundness) has
/// one [OpSpec] per parameter, all sharing the same [type] but different
/// [paramKey] values. The UI groups specs that share a [group] name
/// under a section header.
///
/// [EditorSession.setScalar] uses the identity to decide whether to drop
/// the op when *all* of its parameters return to identity — keeping the
/// shader chain short.
class OpSpec {
  const OpSpec({
    required this.type,
    required this.label,
    required this.category,
    required this.min,
    required this.max,
    required this.identity,
    this.paramKey = 'value',
    this.group,
    this.description,
  });

  final String type;
  final String label;
  final OpCategory category;
  final double min;
  final double max;
  final double identity;
  final String paramKey;

  /// Optional display group (e.g. "Vignette"). Sibling specs with the
  /// same group + category render as a single collapsible section in
  /// the LightroomPanel.
  final String? group;

  /// Optional user-facing description shown as a tooltip when the user
  /// long-presses the slider label. Short, plain-English explanations.
  final String? description;

  bool isIdentity(double value) => (value - identity).abs() < 1e-4;
}

// NOTE: `optics` (lens corrections) was removed in Phase II.5 because it
// had zero registered specs and no roadmap entry in Phases III–IX. When lens
// correction work is scoped, add it back here — see docs/decisions/optics-tab.md.
enum OpCategory { light, color, effects, detail, geometry }

extension OpCategoryX on OpCategory {
  String get label {
    switch (this) {
      case OpCategory.light:
        return 'Light';
      case OpCategory.color:
        return 'Color';
      case OpCategory.effects:
        return 'Effects';
      case OpCategory.detail:
        return 'Detail';
      case OpCategory.geometry:
        return 'Geometry';
    }
  }
}

/// Canonical registry of every adjustable parameter shipped up through
/// Phase 5. Widgets iterate this via [OpSpecs.forCategory] to build
/// slider panels; `EditorSession` iterates it via [OpSpecs.paramsForType]
/// to know whether an op should be dropped when all its sliders are at
/// identity.
class OpSpecs {
  OpSpecs._();

  static const List<OpSpec> all = [
    // ===== LIGHT =====
    OpSpec(
      type: EditOpType.exposure,
      label: 'Exposure',
      category: OpCategory.light,
      min: -2,
      max: 2,
      identity: 0,
      description: 'Overall brightness in stops. +1 stop doubles light intensity.',
    ),
    OpSpec(
      type: EditOpType.brightness,
      label: 'Brightness',
      category: OpCategory.light,
      min: -1,
      max: 1,
      identity: 0,
      description: 'Additive lightness adjustment across the whole image.',
    ),
    OpSpec(
      type: EditOpType.contrast,
      label: 'Contrast',
      category: OpCategory.light,
      min: -1,
      max: 1,
      identity: 0,
      description:
          'Expand or compress the tonal range around mid-grey. Positive = punchier, negative = flatter.',
    ),
    OpSpec(
      type: EditOpType.highlights,
      label: 'Highlights',
      category: OpCategory.light,
      min: -1,
      max: 1,
      identity: 0,
      description:
          'Recover or darken bright areas. Negative values rescue blown-out skies.',
    ),
    OpSpec(
      type: EditOpType.shadows,
      label: 'Shadows',
      category: OpCategory.light,
      min: -1,
      max: 1,
      identity: 0,
      description:
          'Lift or deepen dark areas. Positive values reveal detail in shadows.',
    ),
    OpSpec(
      type: EditOpType.whites,
      label: 'Whites',
      category: OpCategory.light,
      min: -1,
      max: 1,
      identity: 0,
      description:
          'Set the white point. Positive pushes more pixels to pure white.',
    ),
    OpSpec(
      type: EditOpType.blacks,
      label: 'Blacks',
      category: OpCategory.light,
      min: -1,
      max: 1,
      identity: 0,
      description:
          'Set the black point. Negative crushes shadows to pure black.',
    ),
    // Levels group (three params on the SAME op type)
    OpSpec(
      type: EditOpType.levels,
      paramKey: 'black',
      label: 'Black Point',
      group: 'Levels',
      category: OpCategory.light,
      min: 0,
      max: 1,
      identity: 0,
      description: 'Input value that becomes pure black.',
    ),
    OpSpec(
      type: EditOpType.levels,
      paramKey: 'white',
      label: 'White Point',
      group: 'Levels',
      category: OpCategory.light,
      min: 0,
      max: 1,
      identity: 1,
      description: 'Input value that becomes pure white.',
    ),
    OpSpec(
      type: EditOpType.levels,
      paramKey: 'gamma',
      label: 'Gamma',
      group: 'Levels',
      category: OpCategory.light,
      min: 0.1,
      max: 4,
      identity: 1,
      description:
          'Midtone bend. Below 1 brightens midtones, above 1 darkens them.',
    ),

    // ===== COLOR =====
    OpSpec(
      type: EditOpType.temperature,
      label: 'Temperature',
      category: OpCategory.color,
      min: -1,
      max: 1,
      identity: 0,
      description:
          'Cool (blue) to warm (yellow) color balance shift.',
    ),
    OpSpec(
      type: EditOpType.tint,
      label: 'Tint',
      category: OpCategory.color,
      min: -1,
      max: 1,
      identity: 0,
      description: 'Green to magenta color balance shift.',
    ),
    OpSpec(
      type: EditOpType.saturation,
      label: 'Saturation',
      category: OpCategory.color,
      min: -1,
      max: 1,
      identity: 0,
      description:
          'Uniformly boost or remove color. -1 is fully monochrome.',
    ),
    OpSpec(
      type: EditOpType.vibrance,
      label: 'Vibrance',
      category: OpCategory.color,
      min: -1,
      max: 1,
      identity: 0,
      description:
          'Smart saturation that boosts subdued colors more than already-saturated ones.',
    ),
    OpSpec(
      type: EditOpType.hue,
      label: 'Hue',
      category: OpCategory.color,
      min: -180,
      max: 180,
      identity: 0,
      description: 'Rotate the entire hue wheel by degrees.',
    ),

    // ===== EFFECTS =====
    OpSpec(
      type: EditOpType.dehaze,
      label: 'Dehaze',
      category: OpCategory.effects,
      min: -1,
      max: 1,
      identity: 0,
      description: 'Remove (positive) or add (negative) atmospheric haze.',
    ),
    OpSpec(
      type: EditOpType.clarity,
      label: 'Clarity',
      category: OpCategory.effects,
      min: -1,
      max: 1,
      identity: 0,
      description:
          'Midtone local contrast. Positive adds bite; negative softens.',
    ),
    // Vignette group
    OpSpec(
      type: EditOpType.vignette,
      paramKey: 'amount',
      label: 'Amount',
      group: 'Vignette',
      category: OpCategory.effects,
      min: -1,
      max: 1,
      identity: 0,
      description: 'Darken (positive) or brighten (negative) the corners.',
    ),
    OpSpec(
      type: EditOpType.vignette,
      paramKey: 'feather',
      label: 'Feather',
      group: 'Vignette',
      category: OpCategory.effects,
      min: 0,
      max: 1,
      identity: 0.4,
      description:
          'Softness of the vignette edge. Higher is a smoother falloff.',
    ),
    OpSpec(
      type: EditOpType.vignette,
      paramKey: 'roundness',
      label: 'Roundness',
      group: 'Vignette',
      category: OpCategory.effects,
      min: 0,
      max: 1,
      identity: 0.5,
      description: '0 follows the image aspect, 1 is a perfect circle.',
    ),
    // Grain group
    OpSpec(
      type: EditOpType.grain,
      paramKey: 'amount',
      label: 'Amount',
      group: 'Grain',
      category: OpCategory.effects,
      min: 0,
      max: 1,
      identity: 0,
      description: 'Strength of the film grain overlay.',
    ),
    OpSpec(
      type: EditOpType.grain,
      paramKey: 'cellSize',
      label: 'Size',
      group: 'Grain',
      category: OpCategory.effects,
      min: 1,
      max: 8,
      identity: 2,
      description: 'Grain cell size in pixels. Bigger = coarser grain.',
    ),
    // Chromatic aberration
    OpSpec(
      type: EditOpType.chromaticAberration,
      paramKey: 'amount',
      label: 'Chromatic Aberration',
      category: OpCategory.effects,
      min: 0,
      max: 1,
      identity: 0,
      description: 'Fake lens color fringing for a dreamy or vintage look.',
    ),
    // Pixelate
    OpSpec(
      type: EditOpType.pixelate,
      paramKey: 'pixelSize',
      label: 'Pixelate',
      category: OpCategory.effects,
      min: 1,
      max: 40,
      identity: 1,
      description: 'Mosaic effect. 1 = no change, 40 = big blocks.',
    ),
    // Halftone group
    OpSpec(
      type: EditOpType.halftone,
      paramKey: 'dotSize',
      label: 'Dot Size',
      group: 'Halftone',
      category: OpCategory.effects,
      min: 2,
      max: 24,
      identity: 2,
      description: 'Size of each halftone dot in pixels.',
    ),
    OpSpec(
      type: EditOpType.halftone,
      paramKey: 'angle',
      label: 'Angle',
      group: 'Halftone',
      category: OpCategory.effects,
      min: 0,
      max: 3.14,
      identity: 0.785,
      description: 'Rotation of the dot grid.',
    ),
    // Glitch
    OpSpec(
      type: EditOpType.glitch,
      paramKey: 'amount',
      label: 'Glitch',
      category: OpCategory.effects,
      min: 0,
      max: 1,
      identity: 0,
      description: 'Random horizontal row displacement — digital distortion.',
    ),
    // Tilt-shift group
    OpSpec(
      type: EditOpType.tiltShift,
      paramKey: 'blurAmount',
      label: 'Blur',
      group: 'Tilt-Shift',
      category: OpCategory.effects,
      min: 0,
      max: 1,
      identity: 0,
      description: 'Blur intensity outside the focus strip.',
    ),
    OpSpec(
      type: EditOpType.tiltShift,
      paramKey: 'focusWidth',
      label: 'Focus Width',
      group: 'Tilt-Shift',
      category: OpCategory.effects,
      min: 0.01,
      max: 0.5,
      identity: 0.15,
      description: 'Half-width of the sharp band. Smaller = stronger effect.',
    ),
    OpSpec(
      type: EditOpType.tiltShift,
      paramKey: 'angle',
      label: 'Angle',
      group: 'Tilt-Shift',
      category: OpCategory.effects,
      min: -1.57,
      max: 1.57,
      identity: 0,
      description: 'Rotation of the focus band in radians.',
    ),
    // Motion blur group
    OpSpec(
      type: EditOpType.motionBlur,
      paramKey: 'strength',
      label: 'Strength',
      group: 'Motion Blur',
      category: OpCategory.effects,
      min: 0,
      max: 1,
      identity: 0,
      description: 'Amount of directional motion blur.',
    ),
    OpSpec(
      type: EditOpType.motionBlur,
      paramKey: 'angle',
      label: 'Angle',
      group: 'Motion Blur',
      category: OpCategory.effects,
      min: -3.14,
      max: 3.14,
      identity: 0,
      description: 'Direction of motion in radians.',
    ),

    // ===== GEOMETRY =====
    OpSpec(
      type: EditOpType.straighten,
      label: 'Straighten',
      category: OpCategory.geometry,
      min: -45,
      max: 45,
      identity: 0,
      description:
          'Fine rotation in degrees. Use to level the horizon after a tilt.',
    ),

    // ===== DETAIL =====
    // Sharpen group
    OpSpec(
      type: EditOpType.sharpen,
      paramKey: 'amount',
      label: 'Amount',
      group: 'Sharpen',
      category: OpCategory.detail,
      min: 0,
      max: 2,
      identity: 0,
      description: 'Unsharp mask strength. Enhances edge contrast.',
    ),
    OpSpec(
      type: EditOpType.sharpen,
      paramKey: 'radius',
      label: 'Radius',
      group: 'Sharpen',
      category: OpCategory.detail,
      min: 0.5,
      max: 3,
      identity: 1,
      description: 'Edge detection radius. Larger finds thicker edges.',
    ),
    // Denoise group
    OpSpec(
      type: EditOpType.denoiseBilateral,
      paramKey: 'sigmaSpatial',
      label: 'Smoothing',
      group: 'Denoise',
      category: OpCategory.detail,
      min: 0,
      max: 4,
      identity: 0,
      description: 'Overall noise reduction strength.',
    ),
    OpSpec(
      type: EditOpType.denoiseBilateral,
      paramKey: 'sigmaRange',
      label: 'Edge Preserve',
      group: 'Denoise',
      category: OpCategory.detail,
      min: 0.05,
      max: 0.5,
      identity: 0.15,
      description: 'Lower keeps edges sharp; higher smooths across them.',
    ),
    OpSpec(
      type: EditOpType.denoiseBilateral,
      paramKey: 'radius',
      label: 'Radius',
      group: 'Denoise',
      category: OpCategory.detail,
      min: 1,
      max: 6,
      identity: 1,
      description: 'Kernel radius. Larger is slower but smoother.',
    ),
  ];

  static List<OpSpec> forCategory(OpCategory cat) =>
      all.where((s) => s.category == cat).toList(growable: false);

  static OpSpec? byType(String type) {
    for (final s in all) {
      if (s.type == type && s.paramKey == 'value') return s;
    }
    return null;
  }

  /// All specs that belong to a given op type. Used by EditorSession to
  /// decide whether ALL parameters of a multi-param op have returned to
  /// identity.
  static List<OpSpec> paramsForType(String type) =>
      all.where((s) => s.type == type).toList(growable: false);
}
