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
  });
  final double amount;
  final double feather;
  final double roundness;
  final double centerX;
  final double centerY;

  ShaderPass toPass() {
    return ShaderPass(
      assetKey: ShaderKeys.vignette,
      setUniforms: (shader, start) {
        shader.setFloat(start + 0, amount);
        shader.setFloat(start + 1, feather);
        shader.setFloat(start + 2, roundness);
        shader.setFloat(start + 3, centerX);
        shader.setFloat(start + 4, centerY);
        return start + 5;
      },
      contentHash: Object.hash(amount, feather, roundness, centerX, centerY),
    );
  }
}

class GrainShader {
  const GrainShader({this.amount = 0.2, this.cellSize = 2.0, this.seed = 1});
  final double amount;
  final double cellSize;
  final int seed;

  ShaderPass toPass() {
    return ShaderPass(
      assetKey: ShaderKeys.grain,
      setUniforms: (shader, start) {
        shader.setFloat(start + 0, amount);
        shader.setFloat(start + 1, cellSize);
        shader.setFloat(start + 2, seed.toDouble());
        return start + 3;
      },
      contentHash: Object.hash(amount, cellSize, seed),
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
