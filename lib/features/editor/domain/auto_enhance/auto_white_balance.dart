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

/// Classical auto white balance: blends the gray-world and white-patch
/// estimates, then converts the implied illuminant correction into
/// deltas for the existing Temperature and Tint sliders (both in
/// [-1, 1]).
///
/// - **Gray world**: assumes the scene's average colour is neutral. An
///   R-mean higher than G-mean → image is warm → temperature should
///   shift cool (negative) to compensate.
/// - **White patch (Retinex)**: assumes the brightest region is white.
///   Uses the 99th percentile of each channel as a white reference.
///
/// We blend the two 50/50 which is the most robust single-parameter
/// classical method on typical consumer photos.
class AutoWhiteBalance {
  const AutoWhiteBalance({this.strength = 1.0, this.maxDelta = 0.5});

  final double strength;
  final double maxDelta;

  AutoWhiteBalanceResult analyze(HistogramStats s) {
    // ---- Gray world ---------------------------------------------------
    final gwGray = (s.rMean + s.gMean + s.bMean) / 3.0;
    final gwR = gwGray == 0 ? 1.0 : gwGray / s.rMean;
    final gwG = gwGray == 0 ? 1.0 : gwGray / s.gMean;
    final gwB = gwGray == 0 ? 1.0 : gwGray / s.bMean;

    // ---- White patch --------------------------------------------------
    final wpMax = [s.r99, s.g99, s.b99].reduce((a, b) => a > b ? a : b);
    final wpR = s.r99 == 0 ? 1.0 : wpMax / s.r99;
    final wpG = s.g99 == 0 ? 1.0 : wpMax / s.g99;
    final wpB = s.b99 == 0 ? 1.0 : wpMax / s.b99;

    // Blend 50/50.
    final gainR = 0.5 * gwR + 0.5 * wpR;
    final gainG = 0.5 * gwG + 0.5 * wpG;
    final gainB = 0.5 * gwB + 0.5 * wpB;

    // Translate channel gains into (temperature, tint) deltas.
    //
    // Our Temperature slider (-1..1) biases the image warm (+) / cool (-):
    //   positive temp ≈ more red, less blue.
    // Our Tint slider biases green(+) / magenta(-):
    //   positive tint ≈ more green.
    //
    // So if gainR > gainB (we need to boost red to make it neutral), the
    // image was cool and we want temp POSITIVE. We use a gentle linear
    // map so the slider never saturates unless the cast is extreme.
    final tempRaw = (gainR - gainB) * 1.2;
    final tintRaw = (gainG - (gainR + gainB) * 0.5) * 1.2;

    final temperatureDelta =
        (tempRaw * strength).clamp(-maxDelta, maxDelta).toDouble();
    final tintDelta =
        (tintRaw * strength).clamp(-maxDelta, maxDelta).toDouble();

    _log.d('blend', {
      'gw': [gwR, gwG, gwB].map((v) => v.toStringAsFixed(2)).toList(),
      'wp': [wpR, wpG, wpB].map((v) => v.toStringAsFixed(2)).toList(),
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
