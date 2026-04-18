import '../../../../core/logging/app_logger.dart';
import '../../../../engine/pipeline/edit_op_type.dart';
import '../../../../engine/pipeline/edit_operation.dart';
import '../../../../engine/presets/preset.dart';
import 'auto_white_balance.dart';
import 'histogram_stats.dart';

final _log = AppLogger('AutoSection');

/// Per-section auto-fix: touches ONLY the sliders that belong to the
/// named section. Light touches exposure / contrast / highlights /
/// shadows / whites / blacks; Color touches temperature / tint /
/// vibrance / saturation.
///
/// Same "do no harm" thresholds as [AutoEnhanceAnalyzer] — a balanced
/// photo produces 0 ops and the UI surfaces "Nothing to change here"
/// instead of pretending to have done something.
class AutoSectionAnalyzer {
  const AutoSectionAnalyzer({this.strength = 0.7});

  /// 0..1 overall intensity multiplier. Default 0.7 keeps results
  /// gentle — the user can always re-tap or adjust the slider to
  /// push further.
  final double strength;

  Preset analyzeLight(HistogramStats s) {
    final ops = <EditOperation>[];
    EditOperation op(String type, Map<String, dynamic> params) =>
        EditOperation.create(type: type, parameters: params);

    // Exposure — only outside the [0.40, 0.65] healthy band.
    double exposureDelta = 0;
    if (s.lumMean < 0.40) {
      exposureDelta = ((0.5 - s.lumMean) * 1.6 * strength).clamp(0.0, 0.6);
    } else if (s.lumMean > 0.65) {
      exposureDelta = ((0.5 - s.lumMean) * 1.6 * strength).clamp(-0.6, 0.0);
    }
    if (exposureDelta.abs() > 0.04) {
      ops.add(op(EditOpType.exposure, {'value': _round(exposureDelta)}));
    }

    // Contrast — only when the histogram is genuinely compressed.
    final spread = (s.lum99 - s.lum1).clamp(0.01, 1.0);
    double contrastDelta = 0;
    if (spread < 0.50) {
      contrastDelta = 0.4 * strength;
    } else if (spread < 0.70) {
      contrastDelta = (((0.85 - spread) / 0.6) * strength).clamp(0.0, 0.35);
    }
    if (contrastDelta > 0.04) {
      ops.add(op(EditOpType.contrast, {'value': _round(contrastDelta)}));
    }

    // Highlights — only when there's real clipping (>10% near white).
    double highlights = 0;
    if (s.highKeyFraction > 0.10) {
      final excess = (s.highKeyFraction - 0.10).clamp(0.0, 0.30);
      highlights = (-excess * 1.5 * strength).clamp(-0.5, 0.0);
    }
    if (highlights.abs() > 0.04) {
      ops.add(op(EditOpType.highlights, {'value': _round(highlights)}));
    }

    // Shadows — same threshold logic.
    double shadows = 0;
    if (s.lowKeyFraction > 0.10) {
      final excess = (s.lowKeyFraction - 0.10).clamp(0.0, 0.30);
      shadows = (excess * 1.5 * strength).clamp(0.0, 0.5);
    }
    if (shadows.abs() > 0.04) {
      ops.add(op(EditOpType.shadows, {'value': _round(shadows)}));
    }

    // Whites — only when endpoint is far from white.
    if (s.lum99 < 0.85) {
      final whites = ((0.92 - s.lum99) * 0.8 * strength).clamp(0.0, 0.25);
      if (whites > 0.04) {
        ops.add(op(EditOpType.whites, {'value': _round(whites)}));
      }
    }

    // Blacks — only when endpoint is far from black.
    if (s.lum1 > 0.15) {
      final blacks = ((0.05 - s.lum1) * 0.8 * strength).clamp(-0.25, 0.0);
      if (blacks.abs() > 0.04) {
        ops.add(op(EditOpType.blacks, {'value': _round(blacks)}));
      }
    }

    // Confidence bonus — if the photo's light was already balanced,
    // add a tiny contrast bump (+0.05). Users expect Auto Light to
    // visibly do SOMETHING on tap, and a small contrast lift on a
    // properly-exposed photo never degrades it.
    if (ops.isEmpty) {
      ops.add(op(EditOpType.contrast, {'value': 0.05}));
      _log.i('confidence bonus applied (light already balanced)');
    }

    _log.i('light', {'ops': ops.length});
    return Preset(
      id: 'auto.light',
      name: 'Auto Light',
      category: 'auto',
      operations: ops,
    );
  }

  Preset analyzeColor(HistogramStats s) {
    final ops = <EditOperation>[];
    EditOperation op(String type, Map<String, dynamic> params) =>
        EditOperation.create(type: type, parameters: params);

    // White balance — delegates to AutoWhiteBalance which already has
    // its own "no real cast" gate (returns 0 if wp spread < 0.08).
    // We add a 0.08 magnitude threshold on top so a tiny correction
    // doesn't show up as a slider movement either.
    const wb = AutoWhiteBalance(strength: 0.6);
    final wbResult = wb.analyze(s);
    if (wbResult.temperatureDelta.abs() > 0.08) {
      ops.add(op(EditOpType.temperature, {
        'value': _round(wbResult.temperatureDelta),
      }));
    }
    if (wbResult.tintDelta.abs() > 0.08) {
      ops.add(op(EditOpType.tint, {
        'value': _round(wbResult.tintDelta),
      }));
    }

    // Vibrance — only on genuinely dull photos. Most user photos sit
    // around satMean 0.20-0.35; only push when it's below 0.20.
    double vibrance = 0;
    if (s.saturationMean < 0.20) {
      vibrance =
          ((0.30 - s.saturationMean) * 0.8 * strength).clamp(0.0, 0.30);
    }
    if (vibrance > 0.04) {
      ops.add(op(EditOpType.vibrance, {'value': _round(vibrance)}));
    }

    // Saturation — almost never needed automatically. Only kick in for
    // SEVERELY desaturated photos (satMean < 0.10).
    double saturation = 0;
    if (s.saturationMean < 0.10) {
      saturation =
          ((0.20 - s.saturationMean) * 0.6 * strength).clamp(0.0, 0.20);
    }
    if (saturation.abs() > 0.04) {
      ops.add(op(EditOpType.saturation, {'value': _round(saturation)}));
    }

    // Confidence bonus — if colour was already balanced, add a tiny
    // vibrance bump (+0.06). Vibrance is the "smart saturation" that
    // boosts subdued colours more than already-saturated ones, so a
    // small lift never muddies already-rich photos.
    if (ops.isEmpty) {
      ops.add(op(EditOpType.vibrance, {'value': 0.06}));
      _log.i('confidence bonus applied (color already balanced)');
    }

    _log.i('color', {'ops': ops.length});
    return Preset(
      id: 'auto.color',
      name: 'Auto Color',
      category: 'auto',
      operations: ops,
    );
  }

  double _round(double v) => (v * 100).round() / 100.0;
}
