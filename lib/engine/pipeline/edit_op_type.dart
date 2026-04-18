/// Canonical string identifiers for every kind of [EditOperation].
///
/// These strings are persisted in JSON pipeline files so they must never
/// change without a migration. New operations get a new constant at the end
/// of their category group.
class EditOpType {
  EditOpType._();

  // --- Color (matrix-composable) ---
  static const brightness = 'color.brightness';
  static const contrast = 'color.contrast';
  static const saturation = 'color.saturation';
  static const hue = 'color.hue';
  static const exposure = 'color.exposure';
  static const temperature = 'color.temperature';
  static const tint = 'color.tint';
  static const channelMixer = 'color.channelMixer';

  // --- Color (non-matrix) ---
  static const highlights = 'color.highlights';
  static const shadows = 'color.shadows';
  static const whites = 'color.whites';
  static const blacks = 'color.blacks';
  static const vibrance = 'color.vibrance';
  static const clarity = 'color.clarity';
  static const dehaze = 'color.dehaze';
  static const levels = 'color.levels';
  static const gamma = 'color.gamma';
  static const toneCurve = 'color.toneCurve';
  static const hsl = 'color.hsl';
  static const splitToning = 'color.splitToning';

  // --- Filters / presets ---
  static const lut3d = 'filter.lut3d';
  static const matrixPreset = 'filter.matrixPreset';

  // --- Effects ---
  static const vignette = 'fx.vignette';
  static const grain = 'fx.grain';
  static const chromaticAberration = 'fx.chromaticAberration';
  static const glitch = 'fx.glitch';
  static const pixelate = 'fx.pixelate';
  static const halftone = 'fx.halftone';
  static const sharpen = 'fx.sharpen';

  // --- Blurs ---
  static const gaussianBlur = 'blur.gaussian';
  static const motionBlur = 'blur.motion';
  static const radialBlur = 'blur.radial';
  static const tiltShift = 'blur.tiltShift';

  // --- Noise ---
  static const denoiseBilateral = 'noise.bilateralDenoise';
  static const denoiseNlm = 'noise.nonLocalMeans';

  // --- Geometry ---
  static const crop = 'geom.crop';
  static const rotate = 'geom.rotate';
  static const flip = 'geom.flip';
  static const straighten = 'geom.straighten';
  static const perspective = 'geom.perspective';

  // --- Layers / compositing ---
  static const drawing = 'layer.drawing';
  static const text = 'layer.text';
  static const sticker = 'layer.sticker';
  static const shape = 'layer.shape';
  static const raster = 'layer.raster';
  static const adjustmentLayer = 'layer.adjustment';

  // --- AI (Memento-backed) ---
  static const aiBackgroundRemoval = 'ai.backgroundRemoval';
  static const aiInpaint = 'ai.inpaint';
  static const aiSuperResolution = 'ai.superResolution';
  static const aiStyleTransfer = 'ai.styleTransfer';
  static const aiFaceBeautify = 'ai.faceBeautify';
  static const aiSkyReplace = 'ai.skyReplace';
  static const aiColorize = 'ai.colorize';

  /// Operations whose effect can be expressed purely as a 5x4 color matrix
  /// and therefore be folded together by `matrix_composer.dart`.
  static const Set<String> matrixComposable = {
    brightness,
    contrast,
    saturation,
    hue,
    exposure,
    channelMixer,
    // NOTE: temperature and tint are linear-ish but non-multiplicative; we
    // keep them out of the matrix fold and apply in the color_grading.frag
    // dedicated uniforms.
  };

  /// Operations that cannot be reversed analytically and therefore require
  /// a Memento snapshot in the history.
  static const Set<String> mementoRequired = {
    aiBackgroundRemoval,
    aiInpaint,
    aiSuperResolution,
    aiStyleTransfer,
    aiFaceBeautify,
    aiSkyReplace,
    aiColorize,
    drawing, // multi-stroke brush sessions
  };

  /// Operations that a preset is allowed to overwrite when applied with
  /// the `reset` policy (Lightroom-style: applying a preset wipes prior
  /// color / tone / filter / effect adjustments so the user always sees
  /// the preset author's intended look).
  ///
  /// Geometry, layer, mask, and AI ops are deliberately excluded — those
  /// represent destructive or structural state that survives a preset.
  static const Set<String> presetReplaceable = {
    // color (matrix)
    brightness, contrast, saturation, hue, exposure,
    temperature, tint, channelMixer,
    // color (non-matrix)
    highlights, shadows, whites, blacks, vibrance, clarity, dehaze,
    levels, gamma, toneCurve, hsl, splitToning,
    // filters
    lut3d, matrixPreset,
    // effects
    vignette, grain, chromaticAberration, glitch,
    pixelate, halftone, sharpen,
    // blurs
    gaussianBlur, motionBlur, radialBlur, tiltShift,
    // noise
    denoiseBilateral, denoiseNlm,
  };

  /// Operations whose preview path uses a shader pass distinct from the
  /// composed color matrix (i.e. they always re-render from the last cached
  /// output).
  static const Set<String> shaderPassRequired = {
    highlights,
    shadows,
    whites,
    blacks,
    vibrance,
    clarity,
    dehaze,
    levels,
    gamma,
    toneCurve,
    hsl,
    splitToning,
    lut3d,
    vignette,
    grain,
    chromaticAberration,
    glitch,
    pixelate,
    halftone,
    sharpen,
    gaussianBlur,
    motionBlur,
    radialBlur,
    tiltShift,
    denoiseBilateral,
    perspective,
  };
}
