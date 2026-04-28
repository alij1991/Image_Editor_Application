/// Canonical string identifiers for every kind of [EditOperation].
///
/// These strings are persisted in JSON pipeline files so they must never
/// change without a migration. New operations get a new constant at the end
/// of their category group.
///
/// **Classifier sets** (matrixComposable / mementoRequired /
/// presetReplaceable / shaderPassRequired) previously lived here as
/// four `const Set<String>` fields. They moved to `OpRegistry` in
/// Phase III.1 — adding a new op now means one entry in
/// `OpRegistry._entries` (with boolean flags) instead of touching four
/// separate sets. Read the current classification via
/// `OpRegistry.matrixComposable` etc. or via the convenience getters on
/// `EditOperation` (`isMatrixComposable`, `requiresMemento`,
/// `needsShaderPass`).
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
  // XVI.23 — Lightroom-style fine-frequency unsharp ("Texture"). Same
  // namespace prefix as clarity since the math is sibling-shaped, but
  // the OpSpec lives in OpCategory.light per the audit phase plan so
  // the slider appears next to brightness/contrast/etc.
  static const texture = 'color.texture';
  static const dehaze = 'color.dehaze';
  static const levels = 'color.levels';
  static const gamma = 'color.gamma';
  static const toneCurve = 'color.toneCurve';
  static const hsl = 'color.hsl';
  static const splitToning = 'color.splitToning';
  // XVI.27 — Lightroom-style three-wheel Color Grading panel
  // (shadows / mids / highlights tints + a global wheel + balance +
  // blending). NB: this is NOT related to the internal
  // `_colorGradingPass` matrix-composer in `pass_builders.dart`,
  // which is a fan-in of the matrix-composable color ops onto
  // `shaders/color_grading.frag`. The audit's "promote colorGrading
  // from a pseudo-op" was loose phrasing — there was never an op of
  // this name; the user-visible Color Grading feature is brand new
  // here, mounting on a separate `shaders/color_grading_3wheel.frag`
  // pass. The matrix-composer keeps its names; this op gets the
  // canonical "colorGrading" identifier.
  static const colorGrading = 'color.colorGrading';

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
  // NOTE: `denoiseNlm` ('noise.nonLocalMeans') was removed in Phase I.7.
  // The op type was in `presetReplaceable` but had no shader, no service,
  // and no `_passesFor()` dispatch — any pipeline carrying it silently
  // rendered unchanged. NLM denoise is O(patch² · search · pixels) and
  // needs a real GPU implementation; until there's product priority to
  // build it, the op type is absent rather than latent. Legacy saved
  // pipelines containing `'noise.nonLocalMeans'` still deserialise — the
  // renderer skips unknown types (see `_passesFor()` branch chain).

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
  // NOTE: `aiColorize` ('ai.colorize') was removed in Phase I.6. No
  // colorization service was ever wired up and the manifest URL was
  // a literal `example.com` placeholder, so the op type was deleted
  // rather than left as reachable vaporware. Legacy saved pipelines
  // containing the string `'ai.colorize'` still deserialise — the
  // renderer just skips them (see `_passesFor()` branch chain).

  // NOTE: the four classifier sets (matrixComposable, mementoRequired,
  // presetReplaceable, shaderPassRequired) moved to `op_registry.dart`
  // in Phase III.1. Adding a new op is now a single entry in
  // `OpRegistry._entries` with boolean flags, instead of keeping four
  // sets in sync. Access the current classification via
  // `OpRegistry.matrixComposable` etc. Legacy pipelines with removed
  // op types still round-trip — the renderer skips unknown strings.
}
