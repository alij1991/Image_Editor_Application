/// Stable asset keys for every fragment shader shipped with the app.
///
/// The keys match the `shaders:` section of `pubspec.yaml`. Use these
/// constants instead of string literals so a rename catches at compile
/// time.
class ShaderKeys {
  ShaderKeys._();

  // Color grading
  static const colorGrading = 'shaders/color_grading.frag';
  static const hsl = 'shaders/hsl.frag';
  static const curves = 'shaders/curves.frag';
  static const highlightsShadows = 'shaders/highlights_shadows.frag';
  static const vibrance = 'shaders/vibrance.frag';
  static const clarity = 'shaders/clarity.frag';
  static const texture = 'shaders/texture.frag';
  static const dehaze = 'shaders/dehaze.frag';
  static const splitToning = 'shaders/split_toning.frag';
  static const levelsGamma = 'shaders/levels_gamma.frag';
  static const lut3d = 'shaders/lut3d.frag';

  // Noise reduction
  static const bilateralDenoise = 'shaders/bilateral_denoise.frag';

  // Blurs
  static const tiltShift = 'shaders/tilt_shift.frag';
  static const motionBlur = 'shaders/motion_blur.frag';
  static const radialBlur = 'shaders/radial_blur.frag';

  // FX
  static const vignette = 'shaders/vignette.frag';
  static const grain = 'shaders/grain.frag';
  static const chromaticAberration = 'shaders/chromatic_aberration.frag';
  static const glitch = 'shaders/glitch.frag';
  static const pixelate = 'shaders/pixelate.frag';
  static const halftone = 'shaders/halftone.frag';
  static const sharpenUnsharp = 'shaders/sharpen_unsharp.frag';

  // Compare / geometry
  static const beforeAfterWipe = 'shaders/before_after_wipe.frag';
  static const perspectiveWarp = 'shaders/perspective_warp.frag';

  /// Every shader the app ships. Used by preload and by tests that want
  /// to verify every key resolves to a valid asset.
  static const all = <String>[
    colorGrading,
    hsl,
    curves,
    highlightsShadows,
    vibrance,
    clarity,
    texture,
    dehaze,
    splitToning,
    levelsGamma,
    lut3d,
    bilateralDenoise,
    tiltShift,
    motionBlur,
    radialBlur,
    vignette,
    grain,
    chromaticAberration,
    glitch,
    pixelate,
    halftone,
    sharpenUnsharp,
    beforeAfterWipe,
    perspectiveWarp,
  ];
}
