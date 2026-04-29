import 'dart:ui' as ui;

import '../shader_keys.dart';
import '../shader_pass.dart';

/// Effect shader wrappers: vignette, grain, chromatic aberration, glitch,
/// pixelate, halftone, sharpen, bilateral denoise, blurs, wipe, warp.

class VignetteShader {
  const VignetteShader({
    this.amount = 0.3,
    this.feather = 0.4,
    this.roundness = 0.5,
    this.centerX = 0.5,
    this.centerY = 0.5,
    required this.subjectMask,
    this.protectStrength = 0.0,
  });
  final double amount;
  final double feather;
  final double roundness;
  final double centerX;
  final double centerY;

  /// XVI.33 — second sampler bound to the latest bg-removal cutout
  /// (or to a 1×1 transparent fallback when no cutout exists). The
  /// shader reads `.a` so the cutout's alpha channel doubles as the
  /// subject mask. Always non-null because Flutter's shader binding
  /// model requires every declared sampler to receive an image; the
  /// fallback is a lazily-cached ui.Image owned by the render driver.
  final ui.Image subjectMask;

  /// XVI.33 — `[0, 1]` blend strength of the subject-protect mask. At
  /// 0 the protect is a no-op and the shader output equals the pre-
  /// XVI.33 vignette. At 1 a fully-masked subject gets exactly the
  /// pre-vignette source colour (no darkening).
  final double protectStrength;

  ShaderPass toPass() {
    return ShaderPass(
      assetKey: ShaderKeys.vignette,
      samplers: [subjectMask],
      setUniforms: (shader, start) {
        shader.setFloat(start + 0, amount);
        shader.setFloat(start + 1, feather);
        shader.setFloat(start + 2, roundness);
        shader.setFloat(start + 3, centerX);
        shader.setFloat(start + 4, centerY);
        shader.setFloat(start + 5, protectStrength);
        return start + 6;
      },
      contentHash: Object.hash(
        amount,
        feather,
        roundness,
        centerX,
        centerY,
        protectStrength,
        identityHashCode(subjectMask),
      ),
    );
  }
}

class GrainShader {
  /// Phase XVI.34 — gained `shadows` / `mids` / `highs` per-band
  /// amplitudes. Defaults are 1.0 across the board so an old
  /// pipeline that only writes `amount` + `cellSize` reads back as
  /// uniform-amplitude grain (matching pre-XVI.34 behaviour).
  const GrainShader({
    this.amount = 0.2,
    this.cellSize = 2.0,
    this.seed = 1,
    this.shadows = 1.0,
    this.mids = 1.0,
    this.highs = 1.0,
  });
  final double amount;
  final double cellSize;
  final int seed;
  final double shadows;
  final double mids;
  final double highs;

  ShaderPass toPass() {
    return ShaderPass(
      assetKey: ShaderKeys.grain,
      setUniforms: (shader, start) {
        shader.setFloat(start + 0, amount);
        shader.setFloat(start + 1, cellSize);
        shader.setFloat(start + 2, seed.toDouble());
        shader.setFloat(start + 3, shadows);
        shader.setFloat(start + 4, mids);
        shader.setFloat(start + 5, highs);
        return start + 6;
      },
      contentHash: Object.hash(amount, cellSize, seed, shadows, mids, highs),
    );
  }
}

class ChromaticAberrationShader {
  const ChromaticAberrationShader({this.amount = 0.3});
  final double amount;

  ShaderPass toPass() {
    return ShaderPass(
      assetKey: ShaderKeys.chromaticAberration,
      setUniforms: (shader, start) {
        shader.setFloat(start + 0, amount);
        return start + 1;
      },
      contentHash: amount.hashCode,
    );
  }
}

class GlitchShader {
  const GlitchShader({this.amount = 0.3, this.time = 0});
  final double amount;
  final double time;

  ShaderPass toPass() {
    return ShaderPass(
      assetKey: ShaderKeys.glitch,
      setUniforms: (shader, start) {
        shader.setFloat(start + 0, amount);
        shader.setFloat(start + 1, time);
        return start + 2;
      },
      contentHash: Object.hash(amount, time),
    );
  }
}

class PixelateShader {
  const PixelateShader({this.pixelSize = 8});
  final double pixelSize;

  ShaderPass toPass() {
    return ShaderPass(
      assetKey: ShaderKeys.pixelate,
      setUniforms: (shader, start) {
        shader.setFloat(start + 0, pixelSize);
        return start + 1;
      },
      contentHash: pixelSize.hashCode,
    );
  }
}

class HalftoneShader {
  const HalftoneShader({this.dotSize = 6, this.angle = 0.785});
  final double dotSize;
  final double angle;

  ShaderPass toPass() {
    return ShaderPass(
      assetKey: ShaderKeys.halftone,
      setUniforms: (shader, start) {
        shader.setFloat(start + 0, dotSize);
        shader.setFloat(start + 1, angle);
        return start + 2;
      },
      contentHash: Object.hash(dotSize, angle),
    );
  }
}

class SharpenUnsharpShader {
  const SharpenUnsharpShader({this.amount = 0.5, this.radius = 1.0});
  final double amount;
  final double radius;

  ShaderPass toPass() {
    return ShaderPass(
      assetKey: ShaderKeys.sharpenUnsharp,
      setUniforms: (shader, start) {
        shader.setFloat(start + 0, amount);
        shader.setFloat(start + 1, radius);
        return start + 2;
      },
      contentHash: Object.hash(amount, radius),
    );
  }
}

class BilateralDenoiseShader {
  const BilateralDenoiseShader({
    this.sigmaSpatial = 2.0,
    this.sigmaRange = 0.15,
    this.radius = 4.0,
  });
  final double sigmaSpatial;
  final double sigmaRange;
  final double radius;

  ShaderPass toPass() {
    return ShaderPass(
      assetKey: ShaderKeys.bilateralDenoise,
      setUniforms: (shader, start) {
        shader.setFloat(start + 0, sigmaSpatial);
        shader.setFloat(start + 1, sigmaRange);
        shader.setFloat(start + 2, radius);
        return start + 3;
      },
      contentHash: Object.hash(sigmaSpatial, sigmaRange, radius),
    );
  }
}

class TiltShiftShader {
  const TiltShiftShader({
    this.focusX = 0.5,
    this.focusY = 0.5,
    this.focusWidth = 0.15,
    this.blurAmount = 0.5,
    this.angle = 0,
  });
  final double focusX;
  final double focusY;
  final double focusWidth;
  final double blurAmount;
  final double angle;

  ShaderPass toPass() {
    return ShaderPass(
      assetKey: ShaderKeys.tiltShift,
      setUniforms: (shader, start) {
        shader.setFloat(start + 0, focusX);
        shader.setFloat(start + 1, focusY);
        shader.setFloat(start + 2, focusWidth);
        shader.setFloat(start + 3, blurAmount);
        shader.setFloat(start + 4, angle);
        return start + 5;
      },
      contentHash:
          Object.hash(focusX, focusY, focusWidth, blurAmount, angle),
    );
  }
}

class MotionBlurShader {
  const MotionBlurShader({
    this.directionX = 1.0,
    this.directionY = 0.0,
    this.samples = 16,
    this.strength = 0.5,
  });
  final double directionX;
  final double directionY;
  final double samples;
  final double strength;

  ShaderPass toPass() {
    return ShaderPass(
      assetKey: ShaderKeys.motionBlur,
      setUniforms: (shader, start) {
        shader.setFloat(start + 0, directionX);
        shader.setFloat(start + 1, directionY);
        shader.setFloat(start + 2, samples);
        shader.setFloat(start + 3, strength);
        return start + 4;
      },
      contentHash: Object.hash(directionX, directionY, samples, strength),
    );
  }
}

class RadialBlurShader {
  const RadialBlurShader({
    this.centerX = 0.5,
    this.centerY = 0.5,
    this.strength = 0.5,
  });
  final double centerX;
  final double centerY;
  final double strength;

  ShaderPass toPass() {
    return ShaderPass(
      assetKey: ShaderKeys.radialBlur,
      setUniforms: (shader, start) {
        shader.setFloat(start + 0, centerX);
        shader.setFloat(start + 1, centerY);
        shader.setFloat(start + 2, strength);
        return start + 3;
      },
      contentHash: Object.hash(centerX, centerY, strength),
    );
  }
}

class BeforeAfterWipeShader {
  const BeforeAfterWipeShader({
    required this.original,
    this.splitPos = 0.5,
    this.angle = 0,
  });
  final ui.Image original;
  final double splitPos;
  final double angle;

  ShaderPass toPass() {
    return ShaderPass(
      assetKey: ShaderKeys.beforeAfterWipe,
      samplers: [original],
      setUniforms: (shader, start) {
        shader.setFloat(start + 0, splitPos);
        shader.setFloat(start + 1, angle);
        return start + 2;
      },
      contentHash: Object.hash(splitPos, angle, identityHashCode(original)),
    );
  }
}

/// XVI.46 — Brown-Conrady radial distortion correction. Mirrors the
/// per-frame uniform layout of `lens_distortion.frag`. The pass
/// builder skips this shader when both coefficients are zero so the
/// "no profile matched" path stays a no-op.
class LensDistortionShader {
  const LensDistortionShader({required this.k1, required this.k2});

  /// Second-order radial coefficient. Negative = barrel correction
  /// (push corners outward), positive = pincushion correction.
  final double k1;

  /// Fourth-order radial coefficient. Refines the correction at the
  /// extreme corners; almost always smaller magnitude than [k1].
  final double k2;

  ShaderPass toPass() {
    return ShaderPass(
      assetKey: ShaderKeys.lensDistortion,
      setUniforms: (shader, start) {
        shader.setFloat(start + 0, k1);
        shader.setFloat(start + 1, k2);
        return start + 2;
      },
      contentHash: Object.hash(k1, k2),
    );
  }
}

/// XVI.40 — depth-aware lens blur. Two-sampler shader pass: the source
/// is bound as `u_texture`, the depth map as `u_depth`. Pass builder
/// in `pass_builders.dart` reads the cached depth map from the
/// session and only emits a pass when both the depth map is ready
/// and the aperture is above the noise floor.
///
/// Bokeh shape is a parametric integer (0=circle, 1=5-blade,
/// 2=cat's-eye); the shader's per-tap mask switches accordingly.
class LensBlurShader {
  const LensBlurShader({
    required this.aperture,
    required this.focusX,
    required this.focusY,
    required this.bokehShape,
    required this.depthMap,
  });

  /// Bokeh radius scale in `[0, 1]`. The shader caps the actual UV
  /// radius at 6% of image width so kernels stay bounded even at
  /// `aperture=1`.
  final double aperture;

  /// Normalised focus point in `[0, 1]`. The shader samples the depth
  /// map at this location to derive the in-focus depth.
  final double focusX;
  final double focusY;

  /// 0=circle, 1=5-blade, 2=cat's-eye. The per-tap mask in the shader
  /// switches based on this value (clamped to `[0, 2]` server-side).
  final int bokehShape;

  /// Single-channel inverse-depth map (red channel carries the depth
  /// value; depth_estimator.dart copies the same value to G/B for
  /// any sampling format). Bound as `u_depth`.
  final ui.Image depthMap;

  ShaderPass toPass() {
    return ShaderPass(
      assetKey: ShaderKeys.lensBlur,
      samplers: [depthMap],
      setUniforms: (shader, start) {
        shader.setFloat(start + 0, aperture);
        shader.setFloat(start + 1, focusX);
        shader.setFloat(start + 2, focusY);
        shader.setFloat(start + 3, bokehShape.toDouble());
        return start + 4;
      },
      contentHash: Object.hash(
        aperture,
        focusX,
        focusY,
        bokehShape,
        identityHashCode(depthMap),
      ),
    );
  }
}

class PerspectiveWarpShader {
  /// 3x3 homography matrix in row-major order. `toPass` uploads it as three
  /// `vec3` uniforms (`u_row0`, `u_row1`, `u_row2`) to match the shader.
  const PerspectiveWarpShader({required this.homography})
      : assert(homography.length == 9);

  final List<double> homography;

  ShaderPass toPass() {
    return ShaderPass(
      assetKey: ShaderKeys.perspectiveWarp,
      setUniforms: (shader, start) {
        var i = start;
        for (final v in homography) {
          shader.setFloat(i++, v);
        }
        return i;
      },
      contentHash: Object.hashAll(homography),
    );
  }
}
