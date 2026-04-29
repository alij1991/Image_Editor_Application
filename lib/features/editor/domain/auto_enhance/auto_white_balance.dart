import 'dart:math' as math;

import '../../../../core/logging/app_logger.dart';
import '../../../../engine/pipeline/edit_op_type.dart';
import '../../../../engine/pipeline/edit_operation.dart';
import '../../../../engine/presets/preset.dart';
import 'histogram_stats.dart';

final _log = AppLogger('AutoWB');

class AutoWhiteBalanceResult {
  const AutoWhiteBalanceResult({
    required this.temperatureDelta,
    required this.tintDelta,
  });
  final double temperatureDelta;
  final double tintDelta;
}

/// Auto white balance: estimates the scene illuminant and converts the
/// implied correction into deltas for the existing Temperature and
/// Tint sliders (both in `[-1, 1]`).
///
/// ## Algorithms in priority order
///
/// 1. **Log-chroma peak (XVI.32 — FFT color constancy spirit)**.
///    Uses the 2D log-chroma histogram from [HistogramStats]
///    (`log2(R/G) × log2(B/G)`), 3×3 average-smoothed, and finds the
///    peak bin. The peak is the dominant chromaticity of the scene —
///    Barron 2017 showed this is a stronger illuminant estimator than
///    gray-world or white-patch on scenes with heavy color casts.
///    Used when the histogram has a clear peak (peak/mean ratio above
///    [_kLcPeakRatioThreshold]).
///
/// 2. **Gray world + white patch blend** (pre-XVI.32 fallback). Used
///    when log-chroma can't find a confident peak — typically very
///    flat / monochrome / low-light scenes where the histogram is
///    too sparse for peak finding to be reliable.
///
/// Both algorithms eventually produce `(gainR, gainG, gainB)` and run
/// the same gain → slider mapping. The two-tier design means the new
/// log-chroma path can land without regressing on inputs the old
/// blend already handled correctly.
class AutoWhiteBalance {
  const AutoWhiteBalance({this.strength = 1.0, this.maxDelta = 0.5});

  final double strength;
  final double maxDelta;

  /// Minimum peak/mean ratio for the log-chroma path to be trusted.
  /// Below this the histogram is too flat (e.g., near-monochrome
  /// scenes) to give a reliable peak; we fall back to gray-world.
  static const double _kLcPeakRatioThreshold = 3.0;

  /// Minimum sample count in the log-chroma histogram. Tiny crops or
  /// very dark / very washed-out images leave too few pixels in the
  /// log-chroma grid for peak finding; below this many samples we
  /// fall back to gray-world.
  static const int _kLcMinSamples = 256;

  /// Empirical scale converting `log2(m_R/m_B)` (the shader's
  /// kelvin-curve gain ratio at slider value 1) into the slider
  /// units the user drags. Sampling the shader at temp=±1 gives
  /// `log2(m_R/m_B) ≈ ±0.6` so a temp slider of 1.0 corresponds to
  /// a 0.6-unit shift in the log-chroma R/B axis.
  static const double _kTempSliderScale = 0.6;

  /// Empirical scale converting the green/magenta tint slider's
  /// log-chroma effect into slider units. At tint=±1 the shader's
  /// `log2(m_G^2 / (m_R*m_B))` shifts by about ±0.83.
  static const double _kTintSliderScale = 0.83;

  AutoWhiteBalanceResult analyze(HistogramStats s) {
    // Try log-chroma first (XVI.32). Falls through to the classical
    // blend on low-confidence peaks.
    final lc = _logChromaPeakEstimate(s);
    if (lc != null) {
      _log.d('log-chroma peak', {
        'temp': lc.temperatureDelta.toStringAsFixed(2),
        'tint': lc.tintDelta.toStringAsFixed(2),
      });
      return AutoWhiteBalanceResult(
        temperatureDelta: _round(lc.temperatureDelta),
        tintDelta: _round(lc.tintDelta),
      );
    }
    return _classicalBlend(s);
  }

  /// XVI.32 — log-chroma peak estimate. Returns null when the
  /// histogram is too flat / sparse for peak finding to be reliable.
  AutoWhiteBalanceResult? _logChromaPeakEstimate(HistogramStats s) {
    if (s.logChromaSampleCount < _kLcMinSamples) return null;
    const n = HistogramStats.kLogChromaBins;
    if (s.logChromaHist.length != n * n) return null;

    // 3×3 average smoothing. Cheap and reduces single-pixel-spike
    // false peaks. The Barron paper uses a learned 1D-x-1D Gaussian
    // via FFT; for a starting-point Auto button this simpler kernel
    // is enough.
    final smoothed = List<double>.filled(n * n, 0);
    for (var v = 0; v < n; v++) {
      for (var u = 0; u < n; u++) {
        var sum = 0;
        var cnt = 0;
        for (var dv = -1; dv <= 1; dv++) {
          final vi = v + dv;
          if (vi < 0 || vi >= n) continue;
          for (var du = -1; du <= 1; du++) {
            final ui = u + du;
            if (ui < 0 || ui >= n) continue;
            sum += s.logChromaHist[vi * n + ui];
            cnt++;
          }
        }
        smoothed[v * n + u] = cnt == 0 ? 0 : sum / cnt;
      }
    }

    // Find peak.
    var peakIdx = 0;
    var peakVal = smoothed[0];
    var totalSum = 0.0;
    var nonZero = 0;
    for (var i = 0; i < smoothed.length; i++) {
      final v = smoothed[i];
      if (v > peakVal) {
        peakVal = v;
        peakIdx = i;
      }
      if (v > 0) {
        totalSum += v;
        nonZero++;
      }
    }
    if (peakVal <= 0 || nonZero == 0) return null;
    final mean = totalSum / nonZero;
    if (peakVal < mean * _kLcPeakRatioThreshold) return null;

    final peakV = peakIdx ~/ n;
    final peakU = peakIdx % n;

    // Convert bin centre to log2 units. Bin (n/2, n/2) maps to (0, 0)
    // — i.e. neutral grey at the histogram centre.
    const range = HistogramStats.kLogChromaRange;
    final ustar = (peakU + 0.5) * (2 * range / n) - range;
    final vstar = (peakV + 0.5) * (2 * range / n) - range;

    return _gainToSliderDeltas(ustar: ustar, vstar: vstar);
  }

  /// Map `(u*, v*) = (log2(R/G), log2(B/G))` of the dominant chroma to
  /// `(temperature, tint)` slider deltas. The shader's white-balance
  /// stack inverts these: the slider value we compute, when applied,
  /// neutralises the cast.
  ///
  /// ```
  /// log2(m_R/m_B) = vstar - ustar  → temp = (v* - u*) / TEMP_SCALE
  /// log2(m_G^2/(m_R*m_B)) = -(u*+v*) → tint = -(u*+v*) / TINT_SCALE
  /// ```
  AutoWhiteBalanceResult _gainToSliderDeltas({
    required double ustar,
    required double vstar,
  }) {
    final tempRaw = (vstar - ustar) / _kTempSliderScale;
    final tintRaw = -(ustar + vstar) / _kTintSliderScale;
    final tempD = (tempRaw * strength).clamp(-maxDelta, maxDelta).toDouble();
    final tintD = (tintRaw * strength).clamp(-maxDelta, maxDelta).toDouble();
    return AutoWhiteBalanceResult(
      temperatureDelta: tempD,
      tintDelta: tintD,
    );
  }

  /// Pre-XVI.32 blend. Gray-world + white-patch with an early-out for
  /// already-neutral scenes.
  AutoWhiteBalanceResult _classicalBlend(HistogramStats s) {
    // ---- Gray world ---------------------------------------------------
    // The classic "average colour is grey" assumption. Cheap and robust
    // for indoor / mixed-lighting shots, but unreliable for scenes that
    // are intrinsically not-neutral (sunsets, snow, foliage).
    final gwGray = (s.rMean + s.gMean + s.bMean) / 3.0;
    final gwR = gwGray == 0 ? 1.0 : gwGray / s.rMean;
    final gwG = gwGray == 0 ? 1.0 : gwGray / s.gMean;
    final gwB = gwGray == 0 ? 1.0 : gwGray / s.bMean;

    // ---- White patch --------------------------------------------------
    // Assumes the brightest region is white. More reliable than gray-
    // world for outdoor scenes with a clear sky / specular highlights.
    final wpMax = [s.r99, s.g99, s.b99].reduce((a, b) => a > b ? a : b);
    final wpR = s.r99 == 0 ? 1.0 : wpMax / s.r99;
    final wpG = s.g99 == 0 ? 1.0 : wpMax / s.g99;
    final wpB = s.b99 == 0 ? 1.0 : wpMax / s.b99;

    // ---- Cast detection ----------------------------------------------
    // Trust the white-patch result more for cast detection — gray-world
    // alone produces false positives on naturally non-neutral scenes
    // (sunsets, foliage, indoor amber). If the white-patch gains are
    // close to (1, 1, 1), the brightest part of the image is already
    // near-neutral white and we should NOT adjust regardless of what
    // gray-world thinks.
    final wpSpread =
        math.max(wpR, math.max(wpG, wpB)) -
            math.min(wpR, math.min(wpG, wpB));
    if (wpSpread < 0.08) {
      // No real cast — leave the photo alone.
      _log.d('no cast (wp spread too small)', {
        'wpSpread': wpSpread.toStringAsFixed(3),
      });
      return const AutoWhiteBalanceResult(
        temperatureDelta: 0,
        tintDelta: 0,
      );
    }

    // Blend gray-world and white-patch. Weight white-patch higher
    // because it's more discriminating about real casts.
    final gainR = 0.35 * gwR + 0.65 * wpR;
    final gainG = 0.35 * gwG + 0.65 * wpG;
    final gainB = 0.35 * gwB + 0.65 * wpB;

    // Translate channel gains into (temperature, tint) deltas.
    //   Temperature (-1..1): positive = warm (more red, less blue).
    //   Tint (-1..1): positive = green push, negative = magenta push.
    // If we need to boost red (gainR > gainB), the image was cool, so
    // temperature should go POSITIVE.
    //
    // The 0.7 multiplier (was 1.2) keeps the correction gentle so a
    // small cast doesn't slam the temperature slider.
    final tempRaw = (gainR - gainB) * 0.7;
    final tintRaw = (gainG - (gainR + gainB) * 0.5) * 0.7;

    final temperatureDelta =
        (tempRaw * strength).clamp(-maxDelta, maxDelta).toDouble();
    final tintDelta =
        (tintRaw * strength).clamp(-maxDelta, maxDelta).toDouble();

    _log.d('blend', {
      'gw': [gwR, gwG, gwB].map((v) => v.toStringAsFixed(2)).toList(),
      'wp': [wpR, wpG, wpB].map((v) => v.toStringAsFixed(2)).toList(),
      'wpSpread': wpSpread.toStringAsFixed(3),
      'gain': [gainR, gainG, gainB].map((v) => v.toStringAsFixed(2)).toList(),
      'temp': temperatureDelta.toStringAsFixed(2),
      'tint': tintDelta.toStringAsFixed(2),
    });

    return AutoWhiteBalanceResult(
      temperatureDelta: _round(temperatureDelta),
      tintDelta: _round(tintDelta),
    );
  }

  /// Convenience: wrap [analyze] into a [Preset] so the caller can feed
  /// it straight into `session.applyPreset`.
  Preset asPreset(HistogramStats s) {
    final r = analyze(s);
    final ops = <EditOperation>[];
    EditOperation op(String type, Map<String, dynamic> params) =>
        EditOperation.create(type: type, parameters: params);
    if (r.temperatureDelta.abs() > 0.02) {
      ops.add(op(EditOpType.temperature, {'value': r.temperatureDelta}));
    }
    if (r.tintDelta.abs() > 0.02) {
      ops.add(op(EditOpType.tint, {'value': r.tintDelta}));
    }
    _log.i('preset', {'ops': ops.length});
    return Preset(
      id: 'auto.whiteBalance',
      name: 'Auto White Balance',
      category: 'auto',
      operations: ops,
    );
  }

  double _round(double v) => (v * 100).round() / 100.0;
}
