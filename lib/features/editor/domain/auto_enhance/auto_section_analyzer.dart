import 'dart:math' as math;

import '../../../../core/logging/app_logger.dart';
import '../../../../engine/pipeline/edit_op_type.dart';
import '../../../../engine/pipeline/edit_operation.dart';
import '../../../../engine/presets/preset.dart';
import 'auto_white_balance.dart';
import 'histogram_stats.dart';

final _log = AppLogger('AutoSection');

/// Per-section auto-fix: touches ONLY the sliders that belong to the
/// named section. Light touches exposure/contrast/highlights/shadows/
/// whites/blacks; Color touches temperature/tint/vibrance/saturation.
///
/// Returns a [Preset] so the caller can land it as one atomic commit
/// via [EditorSession.applyPreset].
class AutoSectionAnalyzer {
  const AutoSectionAnalyzer({this.strength = 1.0});

  final double strength;

  Preset analyzeLight(HistogramStats s) {
    final ops = <EditOperation>[];
    EditOperation op(String type, Map<String, dynamic> params) =>
        EditOperation.create(type: type, parameters: params);

    final exposureDelta = ((0.5 - s.lumMean) * 2.4 * strength).clamp(-0.6, 0.6);
    if (exposureDelta.abs() > 0.02) {
      ops.add(op(EditOpType.exposure, {'value': _round(exposureDelta)}));
    }
    final spread = (s.lum99 - s.lum1).clamp(0.01, 1.0);
    final contrastDelta = (((0.96 - spread) / 0.5) * strength).clamp(-0.15, 0.4);
    if (contrastDelta.abs() > 0.02) {
      ops.add(op(EditOpType.contrast, {'value': _round(contrastDelta)}));
    }
    double highlights = 0;
    if (s.highKeyFraction > 0.05) {
      highlights =
          (-math.min(0.5, s.highKeyFraction * 3.0) * strength).clamp(-0.5, 0.0);
    } else if (s.lum99 > 0.97) {
      highlights = -0.15 * strength;
    }
    if (highlights.abs() > 0.02) {
      ops.add(op(EditOpType.highlights, {'value': _round(highlights)}));
    }
    double shadows = 0;
    if (s.lowKeyFraction > 0.05) {
      shadows =
          (math.min(0.5, s.lowKeyFraction * 3.0) * strength).clamp(0.0, 0.5);
    } else if (s.lum1 < 0.03) {
      shadows = 0.15 * strength;
    }
    if (shadows.abs() > 0.02) {
      ops.add(op(EditOpType.shadows, {'value': _round(shadows)}));
    }
    if (s.lum99 < 0.92) {
      final whites = ((0.95 - s.lum99) * strength).clamp(0.0, 0.3);
      if (whites > 0.02) {
        ops.add(op(EditOpType.whites, {'value': _round(whites)}));
      }
    }
    if (s.lum1 > 0.08) {
      final blacks = ((0.03 - s.lum1) * strength).clamp(-0.3, 0.0);
      if (blacks.abs() > 0.02) {
        ops.add(op(EditOpType.blacks, {'value': _round(blacks)}));
      }
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

    // Temperature + tint via the shared auto-WB block.
    const wb = AutoWhiteBalance();
    final wbResult = wb.analyze(s);
    if (wbResult.temperatureDelta.abs() > 0.02) {
      ops.add(op(EditOpType.temperature, {
        'value': _round(wbResult.temperatureDelta * strength),
      }));
    }
    if (wbResult.tintDelta.abs() > 0.02) {
      ops.add(op(EditOpType.tint, {
        'value': _round(wbResult.tintDelta * strength),
      }));
    }

    // Vibrance — lift muted photos, leave saturated ones alone.
    final vibrance = ((0.35 - s.saturationMean) * 0.6 * strength).clamp(0.0, 0.35);
    if (vibrance > 0.02) {
      ops.add(op(EditOpType.vibrance, {'value': _round(vibrance)}));
    }

    // Saturation — very small bump, or none if already saturated.
    final saturation =
        ((0.30 - s.saturationMean) * 0.25 * strength).clamp(-0.1, 0.15);
    if (saturation.abs() > 0.02) {
      ops.add(op(EditOpType.saturation, {'value': _round(saturation)}));
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
