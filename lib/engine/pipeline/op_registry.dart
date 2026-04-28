import 'edit_op_type.dart';
import 'op_spec.dart';

/// Single registration for an op type. Carries the classifier flags
/// that used to live on [EditOpType] as four separate `Set<String>`
/// (matrix / memento / shaderPass / presetReplaceable), the slider
/// metadata that used to live in `OpSpecs.all`, and the
/// preset-amount-interpolating-keys set that used to live in
/// `PresetIntensity._interpolatingKeys`.
///
/// Adding a new op is now a single entry in [OpRegistry._entries]:
///
/// ```dart
/// OpRegistration(
///   type: EditOpType.foo,
///   shaderPass: true,
///   presetReplaceable: true,
///   specs: [OpSpec(type: EditOpType.foo, ...)],
///   // interpolatingKeys defaults to {'value'} for single-scalar ops
///   // with paramKey='value'. Multi-param ops or ops whose sole spec
///   // uses a non-'value' paramKey must declare the set explicitly.
/// )
/// ```
///
/// Before this, the same registration required four files to be in
/// sync (`edit_op_type.dart` classifier sets + `op_spec.dart` +
/// `preset_intensity.dart` + the shader wrapper). A missed entry
/// produced a silent bad render or a UI disappearance. The consistency
/// test pins the invariant that every op appears here exactly once.
class OpRegistration {
  const OpRegistration({
    required this.type,
    this.matrixComposable = false,
    this.memento = false,
    this.shaderPass = false,
    this.presetReplaceable = false,
    this.specs = const [],
    this.interpolatingKeys = const {},
  });

  /// Canonical op-type string from [EditOpType]. This is the key for
  /// every lookup in the registry.
  final String type;

  /// True when this op's effect can be expressed as a 5x4 color matrix
  /// (folded into a single pass by `matrix_composer.dart`).
  final bool matrixComposable;

  /// True when reversing this op requires a Memento snapshot (no
  /// analytical inverse). AI ops + multi-stroke drawings.
  final bool memento;

  /// True when this op's preview path uses a dedicated shader pass
  /// distinct from the composed color matrix.
  final bool shaderPass;

  /// True when a preset is allowed to wipe this op on apply
  /// (Lightroom-style "replace the look"). Geometry, layers, and AI
  /// ops are never preset-replaceable.
  final bool presetReplaceable;

  /// Slider specs for this op's UI. Empty for ops with bespoke panels
  /// (curves, HSL, split-toning), composite ops (presets, LUTs), and
  /// structural ops (layers, geometry handles).
  ///
  /// Every spec's `OpSpec.type` must equal this registration's [type].
  /// Pinned by the consistency test.
  final List<OpSpec> specs;

  /// Parameter keys that should interpolate linearly with a preset's
  /// amount slider. Keys not listed here pass through verbatim
  /// whenever `amount > 0` (shape parameters like vignette.feather,
  /// non-numeric colour triples, etc.).
  ///
  /// **Default for scalars**: a single-spec op whose one paramKey is
  /// `'value'` (the scalar default) auto-interpolates that key — see
  /// [effectiveInterpolatingKeys]. This prevents the "forgot to declare
  /// interpolatingKeys, preset Amount silently does nothing" footgun.
  /// Multi-param ops and ops with non-default paramKeys
  /// (e.g. `chromaticAberration` uses `'amount'`) must declare
  /// explicitly.
  final Set<String> interpolatingKeys;

  /// The interpolating keys this registration actually uses at
  /// runtime — falls back to `{'value'}` for single-scalar ops when
  /// [interpolatingKeys] is empty. Multi-param ops, ops whose sole
  /// spec uses a non-`value` paramKey, and ops with no specs all
  /// return the declared [interpolatingKeys] verbatim (empty unless
  /// explicitly populated).
  ///
  /// `OpRegistry.interpolatingKeysFor(type)` reads this, so callers
  /// like `PresetIntensity.blend()` always get the right set.
  Set<String> get effectiveInterpolatingKeys {
    if (interpolatingKeys.isNotEmpty) return interpolatingKeys;
    if (specs.length == 1 && specs.single.paramKey == 'value') {
      return const {'value'};
    }
    return const <String>{};
  }
}

/// Central, declarative registry of every op type the editor knows
/// about.
///
/// The four classifier sets ([matrixComposable], [mementoRequired],
/// [presetReplaceable], [shaderPassRequired]), the [specs] list that
/// `OpSpecs.all` reads, and the per-op [interpolatingKeysFor] lookup
/// that `PresetIntensity` reads all derive from [_entries].
///
/// **Invariant**: every op-type string from [EditOpType] must appear
/// as exactly one entry's [OpRegistration.type]. Pinned by
/// `test/engine/pipeline/registry_consistency_test.dart`.
class OpRegistry {
  OpRegistry._();

  /// The one list. Order within each category matters —
  /// `OpSpecs.forCategory` returns specs in declaration order and
  /// `LightroomPanel` renders them that way.
  static const List<OpRegistration> _entries = [
    // =================================================================
    // LIGHT panel — scalar sliders
    // =================================================================
    OpRegistration(
      type: EditOpType.exposure,
      matrixComposable: true,
      presetReplaceable: true,
      specs: [
        OpSpec(
          type: EditOpType.exposure,
          label: 'Exposure',
          category: OpCategory.light,
          min: -2,
          max: 2,
          identity: 0,
          description:
              'Overall brightness in stops. +1 stop doubles light intensity.',
        ),
      ],
    ),
    OpRegistration(
      type: EditOpType.brightness,
      matrixComposable: true,
      presetReplaceable: true,
      specs: [
        OpSpec(
          type: EditOpType.brightness,
          label: 'Brightness',
          category: OpCategory.light,
          min: -1,
          max: 1,
          identity: 0,
          description:
              'Additive lightness adjustment across the whole image.',
        ),
      ],
    ),
    OpRegistration(
      type: EditOpType.contrast,
      matrixComposable: true,
      presetReplaceable: true,
      specs: [
        OpSpec(
          type: EditOpType.contrast,
          label: 'Contrast',
          category: OpCategory.light,
          min: -1,
          max: 1,
          identity: 0,
          description:
              'Expand or compress the tonal range around mid-grey. '
              'Positive = punchier, negative = flatter.',
        ),
      ],
    ),
    OpRegistration(
      type: EditOpType.highlights,
      shaderPass: true,
      presetReplaceable: true,
      specs: [
        OpSpec(
          type: EditOpType.highlights,
          label: 'Highlights',
          category: OpCategory.light,
          min: -1,
          max: 1,
          identity: 0,
          description:
              'Recover or darken bright areas. Negative values rescue '
              'blown-out skies.',
        ),
      ],
    ),
    OpRegistration(
      type: EditOpType.shadows,
      shaderPass: true,
      presetReplaceable: true,
      specs: [
        OpSpec(
          type: EditOpType.shadows,
          label: 'Shadows',
          category: OpCategory.light,
          min: -1,
          max: 1,
          identity: 0,
          description:
              'Lift or deepen dark areas. Positive values reveal detail '
              'in shadows.',
        ),
      ],
    ),
    OpRegistration(
      type: EditOpType.whites,
      shaderPass: true,
      presetReplaceable: true,
      specs: [
        OpSpec(
          type: EditOpType.whites,
          label: 'Whites',
          category: OpCategory.light,
          min: -1,
          max: 1,
          identity: 0,
          description:
              'Set the white point. Positive pushes more pixels to pure '
              'white.',
        ),
      ],
    ),
    OpRegistration(
      type: EditOpType.blacks,
      shaderPass: true,
      presetReplaceable: true,
      specs: [
        OpSpec(
          type: EditOpType.blacks,
          label: 'Blacks',
          category: OpCategory.light,
          min: -1,
          max: 1,
          identity: 0,
          description:
              'Set the black point. Negative crushes shadows to pure '
              'black.',
        ),
      ],
    ),
    // XVI.23 — Texture (fine-frequency unsharp). Sibling to clarity
    // but unmasked + tighter radius. Lives in the Light panel because
    // its perceptual feel is "brightness-of-detail" rather than the
    // midtone bite that puts clarity on the Effects tab.
    OpRegistration(
      type: EditOpType.texture,
      shaderPass: true,
      presetReplaceable: true,
      specs: [
        OpSpec(
          type: EditOpType.texture,
          label: 'Texture',
          category: OpCategory.light,
          min: -1,
          max: 1,
          identity: 0,
          description:
              'Fine-detail enhance / soften. Distinct from Clarity '
              '(midtone) and Sharpen (edges) — works across the full '
              'luminance range on micro-frequency content (skin '
              'pores, fabric, foliage).',
        ),
      ],
    ),
    OpRegistration(
      type: EditOpType.levels,
      shaderPass: true,
      presetReplaceable: true,
      specs: [
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
          // VIII.15 — wider snap band; gamma's perceptual neutral
          // sits in a broader region than the default 2%.
          snapBand: 0.05,
          description:
              'Midtone bend. Below 1 brightens midtones, above 1 darkens '
              'them.',
        ),
      ],
    ),

    // =================================================================
    // COLOR panel — scalar sliders
    // =================================================================
    OpRegistration(
      type: EditOpType.temperature,
      presetReplaceable: true,
      specs: [
        OpSpec(
          type: EditOpType.temperature,
          label: 'Temperature',
          category: OpCategory.color,
          min: -1,
          max: 1,
          identity: 0,
          description: 'Cool (blue) to warm (yellow) color balance shift.',
        ),
      ],
    ),
    OpRegistration(
      type: EditOpType.tint,
      presetReplaceable: true,
      specs: [
        OpSpec(
          type: EditOpType.tint,
          label: 'Tint',
          category: OpCategory.color,
          min: -1,
          max: 1,
          identity: 0,
          description: 'Green to magenta color balance shift.',
        ),
      ],
    ),
    OpRegistration(
      type: EditOpType.saturation,
      matrixComposable: true,
      presetReplaceable: true,
      specs: [
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
      ],
    ),
    OpRegistration(
      type: EditOpType.vibrance,
      shaderPass: true,
      presetReplaceable: true,
      specs: [
        OpSpec(
          type: EditOpType.vibrance,
          label: 'Vibrance',
          category: OpCategory.color,
          min: -1,
          max: 1,
          identity: 0,
          description:
              'Smart saturation that boosts subdued colors more than '
              'already-saturated ones.',
        ),
      ],
    ),
    OpRegistration(
      type: EditOpType.hue,
      matrixComposable: true,
      presetReplaceable: true,
      specs: [
        OpSpec(
          type: EditOpType.hue,
          label: 'Hue',
          category: OpCategory.color,
          min: -180,
          max: 180,
          identity: 0,
          // VIII.15 — narrower band; the wheel wraps every 360° so
          // small intentional shifts (1-2°) shouldn't snap back.
          snapBand: 0.01,
          description: 'Rotate the entire hue wheel by degrees.',
        ),
      ],
    ),

    // =================================================================
    // EFFECTS panel — scalar sliders
    // =================================================================
    OpRegistration(
      type: EditOpType.dehaze,
      shaderPass: true,
      presetReplaceable: true,
      specs: [
        OpSpec(
          type: EditOpType.dehaze,
          label: 'Dehaze',
          category: OpCategory.effects,
          min: -1,
          max: 1,
          identity: 0,
          description:
              'Remove (positive) or add (negative) atmospheric haze.',
        ),
      ],
    ),
    OpRegistration(
      type: EditOpType.clarity,
      shaderPass: true,
      presetReplaceable: true,
      specs: [
        OpSpec(
          type: EditOpType.clarity,
          label: 'Clarity',
          category: OpCategory.effects,
          min: -1,
          max: 1,
          identity: 0,
          description:
              'Midtone local contrast. Positive adds bite; negative '
              'softens.',
        ),
      ],
    ),
    OpRegistration(
      type: EditOpType.vignette,
      shaderPass: true,
      presetReplaceable: true,
      interpolatingKeys: {'amount'},
      specs: [
        OpSpec(
          type: EditOpType.vignette,
          paramKey: 'amount',
          label: 'Amount',
          group: 'Vignette',
          category: OpCategory.effects,
          min: -1,
          max: 1,
          identity: 0,
          description:
              'Darken (positive) or brighten (negative) the corners.',
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
      ],
    ),
    OpRegistration(
      type: EditOpType.grain,
      shaderPass: true,
      presetReplaceable: true,
      // XVI.34 — `amount` is still the master multiplier; the three
      // band knobs interpolate too so a preset can specify a "shadow-
      // heavy film grain" (`shadows: 1, mids: 0.5, highs: 0.2`) and
      // dial it through the preset Amount slider just like a single
      // value would.
      interpolatingKeys: {'amount', 'shadows', 'mids', 'highs'},
      specs: [
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
        // XVI.34 — luminance-banded grain amplitudes. Default 1.0
        // across all three bands replicates the pre-XVI.34 uniform
        // grain. Pulling `highs` toward 0 is the "natural film"
        // recipe (clean skies, textured midtones, gritty shadows).
        OpSpec(
          type: EditOpType.grain,
          paramKey: 'shadows',
          label: 'Shadows',
          group: 'Bands',
          category: OpCategory.effects,
          min: 0,
          max: 1,
          identity: 1,
          description: 'Grain amplitude in the shadow band.',
        ),
        OpSpec(
          type: EditOpType.grain,
          paramKey: 'mids',
          label: 'Mids',
          group: 'Bands',
          category: OpCategory.effects,
          min: 0,
          max: 1,
          identity: 1,
          description: 'Grain amplitude in the midtone band.',
        ),
        OpSpec(
          type: EditOpType.grain,
          paramKey: 'highs',
          label: 'Highs',
          group: 'Bands',
          category: OpCategory.effects,
          min: 0,
          max: 1,
          identity: 1,
          description: 'Grain amplitude in the highlight band.',
        ),
      ],
    ),
    OpRegistration(
      type: EditOpType.chromaticAberration,
      shaderPass: true,
      presetReplaceable: true,
      specs: [
        OpSpec(
          type: EditOpType.chromaticAberration,
          paramKey: 'amount',
          label: 'Chromatic Aberration',
          category: OpCategory.effects,
          min: 0,
          max: 1,
          identity: 0,
          description:
              'Fake lens color fringing for a dreamy or vintage look.',
        ),
      ],
    ),
    OpRegistration(
      type: EditOpType.pixelate,
      shaderPass: true,
      presetReplaceable: true,
      specs: [
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
      ],
    ),
    OpRegistration(
      type: EditOpType.halftone,
      shaderPass: true,
      presetReplaceable: true,
      specs: [
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
      ],
    ),
    OpRegistration(
      type: EditOpType.glitch,
      shaderPass: true,
      presetReplaceable: true,
      specs: [
        OpSpec(
          type: EditOpType.glitch,
          paramKey: 'amount',
          label: 'Glitch',
          category: OpCategory.effects,
          min: 0,
          max: 1,
          identity: 0,
          description:
              'Random horizontal row displacement — digital distortion.',
        ),
      ],
    ),
    OpRegistration(
      type: EditOpType.tiltShift,
      shaderPass: true,
      presetReplaceable: true,
      specs: [
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
          description:
              'Half-width of the sharp band. Smaller = stronger effect.',
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
      ],
    ),
    OpRegistration(
      type: EditOpType.motionBlur,
      shaderPass: true,
      presetReplaceable: true,
      specs: [
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
      ],
    ),

    // =================================================================
    // GEOMETRY panel — scalar sliders
    // =================================================================
    OpRegistration(
      type: EditOpType.straighten,
      specs: [
        OpSpec(
          type: EditOpType.straighten,
          label: 'Straighten',
          category: OpCategory.geometry,
          min: -45,
          max: 45,
          identity: 0,
          description:
              'Fine rotation in degrees. Use to level the horizon after '
              'a tilt.',
        ),
      ],
    ),

    // =================================================================
    // DETAIL panel — scalar sliders
    // =================================================================
    OpRegistration(
      type: EditOpType.sharpen,
      shaderPass: true,
      presetReplaceable: true,
      interpolatingKeys: {'amount'},
      specs: [
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
      ],
    ),
    OpRegistration(
      type: EditOpType.denoiseBilateral,
      shaderPass: true,
      presetReplaceable: true,
      specs: [
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
      ],
    ),

    // =================================================================
    // Non-scalar color ops (bespoke panels or matrix-only)
    // =================================================================
    OpRegistration(
      type: EditOpType.channelMixer,
      matrixComposable: true,
      presetReplaceable: true,
    ),
    OpRegistration(
      type: EditOpType.gamma,
      shaderPass: true,
      presetReplaceable: true,
    ),
    OpRegistration(
      type: EditOpType.toneCurve,
      shaderPass: true,
      presetReplaceable: true,
    ),
    OpRegistration(
      type: EditOpType.hsl,
      shaderPass: true,
      presetReplaceable: true,
    ),
    OpRegistration(
      type: EditOpType.splitToning,
      shaderPass: true,
      presetReplaceable: true,
    ),
    // XVI.27 — three-wheel Color Grading panel. Bespoke UI (4 color
    // pickers + balance + blending), so no scalar specs; the panel
    // pushes a multi-param map through `EditorSession.setMapParams`.
    OpRegistration(
      type: EditOpType.colorGrading,
      shaderPass: true,
      presetReplaceable: true,
    ),

    // =================================================================
    // Filters / presets (no UI slider — LUT panel / preset strip)
    // =================================================================
    OpRegistration(
      type: EditOpType.lut3d,
      shaderPass: true,
      presetReplaceable: true,
      // A LUT-backed preset should dim its LUT with the Amount slider —
      // at amount=0.5 the LUT blends at half the preset's designed
      // intensity. The renderer clamps the final intensity to [0, 1];
      // see editor_session.dart _passesFor where lut3d is dispatched.
      interpolatingKeys: {'intensity'},
    ),
    OpRegistration(
      type: EditOpType.matrixPreset,
      presetReplaceable: true,
    ),

    // =================================================================
    // Blurs without a slider today (see `knownGaps` in the
    // `shader_pass_required_consistency_test` — tracked in IMPROVEMENTS).
    // =================================================================
    OpRegistration(
      type: EditOpType.gaussianBlur,
      shaderPass: true,
      presetReplaceable: true,
    ),
    OpRegistration(
      type: EditOpType.radialBlur,
      shaderPass: true,
      presetReplaceable: true,
    ),

    // =================================================================
    // Geometry (no-slider forms handled via crop / rotation gestures)
    // =================================================================
    OpRegistration(type: EditOpType.crop),
    OpRegistration(type: EditOpType.rotate),
    OpRegistration(type: EditOpType.flip),
    OpRegistration(
      type: EditOpType.perspective,
      shaderPass: true,
    ),
    // XVI.45 — bespoke panel (no sliders); the `lines` parameter is a
    // List<List<double>> of normalised line quads. Shader-backed via
    // perspective_warp.frag with a homography computed by
    // GuidedUprightSolver.
    OpRegistration(
      type: EditOpType.guidedUpright,
      shaderPass: true,
    ),

    // =================================================================
    // Layers / compositing — no ephemeral slider; bespoke panels
    // =================================================================
    // Drawing is the only layer op that requires a Memento snapshot —
    // multi-stroke brush sessions aren't analytically reversible.
    OpRegistration(
      type: EditOpType.drawing,
      memento: true,
    ),
    OpRegistration(type: EditOpType.text),
    OpRegistration(type: EditOpType.sticker),
    OpRegistration(type: EditOpType.shape),
    OpRegistration(type: EditOpType.raster),
    OpRegistration(type: EditOpType.adjustmentLayer),

    // =================================================================
    // AI (Memento-backed — every AI op wraps its output as a raster
    // that survives undo via memento rather than re-inference)
    // =================================================================
    OpRegistration(
      type: EditOpType.aiBackgroundRemoval,
      memento: true,
    ),
    OpRegistration(
      type: EditOpType.aiInpaint,
      memento: true,
    ),
    OpRegistration(
      type: EditOpType.aiSuperResolution,
      memento: true,
    ),
    OpRegistration(
      type: EditOpType.aiStyleTransfer,
      memento: true,
    ),
    OpRegistration(
      type: EditOpType.aiFaceBeautify,
      memento: true,
    ),
    OpRegistration(
      type: EditOpType.aiSkyReplace,
      memento: true,
    ),
  ];

  // -------------------------------------------------------------------
  // Derived lookups — computed once on first access.
  // -------------------------------------------------------------------

  /// Fast op-type → registration lookup. Returns null for unknown /
  /// removed op types (legacy JSON saves containing e.g. `'ai.colorize'`
  /// or `'noise.nonLocalMeans'`).
  static final Map<String, OpRegistration> byType = {
    for (final e in _entries) e.type: e,
  };

  /// Op types whose effect folds into the composed 5x4 color matrix.
  /// Previously lived as `EditOpType.matrixComposable`.
  static final Set<String> matrixComposable = {
    for (final e in _entries)
      if (e.matrixComposable) e.type,
  };

  /// Op types whose reversal requires a Memento snapshot (no
  /// analytical inverse). Previously `EditOpType.mementoRequired`.
  static final Set<String> mementoRequired = {
    for (final e in _entries)
      if (e.memento) e.type,
  };

  /// Op types a preset is allowed to wipe on apply. Previously
  /// `EditOpType.presetReplaceable`.
  static final Set<String> presetReplaceable = {
    for (final e in _entries)
      if (e.presetReplaceable) e.type,
  };

  /// Op types that use a dedicated shader pass (not the composed color
  /// matrix). Previously `EditOpType.shaderPassRequired`.
  static final Set<String> shaderPassRequired = {
    for (final e in _entries)
      if (e.shaderPass) e.type,
  };

  /// Flattened list of every registered [OpSpec], in declaration order.
  /// `OpSpecs.all` delegates here.
  static final List<OpSpec> specs = [
    for (final e in _entries) ...e.specs,
  ];

  /// Returns the interpolating keys for [type], honouring the scalar
  /// default (single-spec ops whose paramKey is `'value'` auto-
  /// interpolate `'value'` when no explicit set is declared). Empty
  /// set for unknown / unregistered op types (safe fallback — preset
  /// blend passes their params through literally).
  ///
  /// See [OpRegistration.effectiveInterpolatingKeys] for the rule.
  static Set<String> interpolatingKeysFor(String type) =>
      byType[type]?.effectiveInterpolatingKeys ?? const <String>{};

  /// All registered entries in declaration order. For use by the
  /// consistency test and any tooling that enumerates ops.
  static List<OpRegistration> get all => _entries;

  /// Returns the registration for [type], or null if not registered.
  static OpRegistration? forType(String type) => byType[type];
}
