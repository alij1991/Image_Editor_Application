import 'dart:ui' as ui;

import '../shader_keys.dart';
import '../shader_pass.dart';

/// Tonal shader wrappers: highlights/shadows/whites/blacks, vibrance, clarity,
/// dehaze, split toning, levels/gamma. Each wrapper exposes a `toPass()` that
/// returns a ready-to-render [ShaderPass].

class HighlightsShadowsShader {
  const HighlightsShadowsShader({
    this.highlights = 0,
    this.shadows = 0,
    this.whites = 0,
    this.blacks = 0,
  });
  final double highlights;
  final double shadows;
  final double whites;
  final double blacks;

  ShaderPass toPass() {
    return ShaderPass(
      assetKey: ShaderKeys.highlightsShadows,
      setUniforms: (shader, start) {
        shader.setFloat(start + 0, highlights);
        shader.setFloat(start + 1, shadows);
        shader.setFloat(start + 2, whites);
        shader.setFloat(start + 3, blacks);
        return start + 4;
      },
      contentHash: Object.hash(highlights, shadows, whites, blacks),
    );
  }
}

class VibranceShader {
  const VibranceShader({this.vibrance = 0});
  final double vibrance;

  ShaderPass toPass() {
    return ShaderPass(
      assetKey: ShaderKeys.vibrance,
      setUniforms: (shader, start) {
        shader.setFloat(start + 0, vibrance);
        return start + 1;
      },
      contentHash: vibrance.hashCode,
    );
  }
}

class ClarityShader {
  /// Phase XI.0.5: [ClarityShader] is now self-contained — the fragment
  /// shader computes its own 9-tap Gaussian blur inline, so callers no
  /// longer supply a pre-blurred sampler. Pre-XI.0.5 the pass required
  /// a `blurred` input that no pass builder ever generated, so every
  /// preset / Auto-Enhance tagged with `clarity` silently rendered as
  /// a no-op.
  const ClarityShader({this.clarity = 0});
  final double clarity;

  ShaderPass toPass() {
    return ShaderPass(
      assetKey: ShaderKeys.clarity,
      setUniforms: (shader, start) {
        shader.setFloat(start + 0, clarity);
        return start + 1;
      },
      contentHash: clarity.hashCode,
    );
  }
}

class DehazeShader {
  const DehazeShader({this.amount = 0});
  final double amount;

  ShaderPass toPass() {
    return ShaderPass(
      assetKey: ShaderKeys.dehaze,
      setUniforms: (shader, start) {
        shader.setFloat(start + 0, amount);
        return start + 1;
      },
      contentHash: amount.hashCode,
    );
  }
}

class SplitToningShader {
  const SplitToningShader({
    required this.highlightColor,
    required this.shadowColor,
    this.balance = 0,
  });
  final List<double> highlightColor; // rgb 0..1 (length 3)
  final List<double> shadowColor;    // rgb 0..1 (length 3)
  final double balance;

  ShaderPass toPass() {
    return ShaderPass(
      assetKey: ShaderKeys.splitToning,
      setUniforms: (shader, start) {
        var i = start;
        shader.setFloat(i++, highlightColor[0]);
        shader.setFloat(i++, highlightColor[1]);
        shader.setFloat(i++, highlightColor[2]);
        shader.setFloat(i++, shadowColor[0]);
        shader.setFloat(i++, shadowColor[1]);
        shader.setFloat(i++, shadowColor[2]);
        shader.setFloat(i++, balance);
        return i;
      },
      contentHash: Object.hash(
        highlightColor[0], highlightColor[1], highlightColor[2],
        shadowColor[0], shadowColor[1], shadowColor[2],
        balance,
      ),
    );
  }
}

class LevelsGammaShader {
  const LevelsGammaShader({
    this.black = 0.0,
    this.white = 1.0,
    this.gamma = 1.0,
  });
  final double black;
  final double white;
  final double gamma;

  ShaderPass toPass() {
    return ShaderPass(
      assetKey: ShaderKeys.levelsGamma,
      setUniforms: (shader, start) {
        shader.setFloat(start + 0, black);
        shader.setFloat(start + 1, white);
        shader.setFloat(start + 2, gamma);
        return start + 3;
      },
      contentHash: Object.hash(black, white, gamma),
    );
  }
}

class HslShader {
  /// Each list must have length 8: red, orange, yellow, green, aqua, blue,
  /// purple, magenta. Values are in [-1, 1].
  const HslShader({
    required this.hueDelta,
    required this.satDelta,
    required this.lumDelta,
  })  : assert(hueDelta.length == 8),
        assert(satDelta.length == 8),
        assert(lumDelta.length == 8);

  final List<double> hueDelta;
  final List<double> satDelta;
  final List<double> lumDelta;

  factory HslShader.identity() => HslShader(
        hueDelta: List.filled(8, 0),
        satDelta: List.filled(8, 0),
        lumDelta: List.filled(8, 0),
      );

  ShaderPass toPass() {
    return ShaderPass(
      assetKey: ShaderKeys.hsl,
      setUniforms: (shader, start) {
        var i = start;
        for (final v in hueDelta) {
          shader.setFloat(i++, v);
        }
        for (final v in satDelta) {
          shader.setFloat(i++, v);
        }
        for (final v in lumDelta) {
          shader.setFloat(i++, v);
        }
        return i;
      },
      contentHash: Object.hashAll([...hueDelta, ...satDelta, ...lumDelta]),
    );
  }
}

class CurvesShader {
  const CurvesShader({required this.curveLut, this.enabled = true});
  final ui.Image curveLut;
  final bool enabled;

  ShaderPass toPass() {
    return ShaderPass(
      assetKey: ShaderKeys.curves,
      samplers: [curveLut],
      setUniforms: (shader, start) {
        shader.setFloat(start + 0, enabled ? 1.0 : 0.0);
        return start + 1;
      },
      contentHash: Object.hash(enabled, identityHashCode(curveLut)),
    );
  }
}

class Lut3dShader {
  const Lut3dShader({
    required this.lut,
    this.tileSize = 33,
    this.intensity = 1.0,
  });
  final ui.Image lut;
  final int tileSize;
  final double intensity;

  ShaderPass toPass() {
    return ShaderPass(
      assetKey: ShaderKeys.lut3d,
      samplers: [lut],
      setUniforms: (shader, start) {
        shader.setFloat(start + 0, tileSize.toDouble());
        shader.setFloat(start + 1, intensity);
        return start + 2;
      },
      contentHash: Object.hash(tileSize, intensity, identityHashCode(lut)),
    );
  }
}
