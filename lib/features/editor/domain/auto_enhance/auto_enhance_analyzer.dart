import 'dart:math' as math;

import '../../../../core/logging/app_logger.dart';
import '../../../../engine/pipeline/edit_op_type.dart';
import '../../../../engine/pipeline/edit_operation.dart';
import '../../../../engine/presets/preset.dart';
import 'auto_white_balance.dart';
import 'histogram_stats.dart';

final _log = AppLogger('AutoEnhance');

/// Lightroom-mobile-style one-shot auto-enhance.
///
/// Derives targets for exposure / contrast / highlights / shadows /
/// whites / blacks / vibrance / saturation / temperature / tint from a
/// single [HistogramStats] snapshot, then returns them as a [Preset].
/// The caller applies the preset via [EditorSession.applyPreset] so the
/// whole thing lands as one undoable commit and every slider is still
/// user-adjustable afterwards.
///
/// Algorithm sketch (values clamped conservatively so it never makes a
/// well-exposed photo worse):
///   - exposure: push lumMean toward 0.5, but only partway (strength 0.6)
///   - contrast: expand the 1–99 percentile range toward [0.02, 0.98]
///   - highlights: negative when highKey > 5% (recover blown sky)
///   - shadows:   positive when lowKey  > 5% (open up dark areas)
///   - whites/blacks: small endpoint push if the histogram is bunched
///   - vibrance: inverse of current saturationMean (lift dull photos
///     more than already-saturated ones)
///   - saturation: tiny bump, never more than +0.1
///   - temperature/tint: delegated to [AutoWhiteBalance] so the Auto
///     button always includes a colour correction
class AutoEnhanceAnalyzer {
  const AutoEnhanceAnalyzer({this.strength = 1.0});

  /// 0..1 overall intensity multiplier — 1.0 is "normal" auto, lower
  /// values produce a more conservative result. Useful for a future
  /// "Subtle / Normal / Strong" user pref.
  final double strength;

  Preset analyze(HistogramStats s) {
    final ops = <EditOperation>[];
    EditOperation op(String type, Map<String, dynamic> params) =>
        EditOperation.create(type: type, parameters: params);

    // Exposure — nudge midtone toward 0.5. Mapping: a full stop of
    // exposure (value=1.0 in our slider) shifts luminance by roughly
    // ~0.25, so scale accordingly. Cap at ±0.6 to avoid over-pushing.
    final exposureDelta = ((0.5 - s.lumMean) * 2.4 * strength).clamp(-0.6, 0.6);
    if (exposureDelta.abs() > 0.02) {
      ops.add(op(EditOpType.exposure, {'value': _round(exposureDelta)}));
    }

    // Contrast — if the 1-99 percentile spread is narrow, increase.
    // Target spread 0.96. Map shortfall to [0, 0.4] contrast.
    final spread = (s.lum99 - s.lum1).clamp(0.01, 1.0);
    final contrastDelta = (((0.96 - spread) / 0.5) * strength).clamp(-0.15, 0.4);
    if (contrastDelta.abs() > 0.02) {
      ops.add(op(EditOpType.contrast, {'value': _round(contrastDelta)}));
    }

    // Highlights — recover blown areas.
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

    // Shadows — open up dark areas.
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

    // Whites — small endpoint push if we're not already touching the
    // top of the histogram.
    if (s.lum99 < 0.92) {
      final whites = ((0.95 - s.lum99) * strength).clamp(0.0, 0.3);
      if (whites > 0.02) {
        ops.add(op(EditOpType.whites, {'value': _round(whites)}));
      }
    }

    // Blacks — subtle push if the bottom is floating off 0.
    if (s.lum1 > 0.08) {
      final blacks = ((0.03 - s.lum1) * strength).clamp(-0.3, 0.0);
      if (blacks.abs() > 0.02) {
        ops.add(op(EditOpType.blacks, {'value': _round(blacks)}));
      }
    }

    // Vibrance — boost dull photos, leave saturated ones alone.
    final vibrance = ((0.35 - s.saturationMean) * 0.6 * strength).clamp(0.0, 0.35);
    if (vibrance > 0.02) {
      ops.add(op(EditOpType.vibrance, {'value': _round(vibrance)}));
    }

    // White balance — fold in the AutoWhiteBalance result so a single
    // tap delivers a colour-corrected image too.
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

    _log.i('analyzed', {
      'ops': ops.length,
      'exposure': exposureDelta.toStringAsFixed(2),
      'contrast': contrastDelta.toStringAsFixed(2),
      'highlights': highlights.toStringAsFixed(2),
      'shadows': shadows.toStringAsFixed(2),
      'vibrance': vibrance.toStringAsFixed(2),
      'temperature': wbResult.temperatureDelta.toStringAsFixed(2),
      'tint': wbResult.tintDelta.toStringAsFixed(2),
    });

    return Preset(
      id: 'auto.enhance',
      name: 'Auto Enhance',
      category: 'auto',
      operations: ops,
    );
  }

  double _round(double v) => (v * 100).round() / 100.0;
}
