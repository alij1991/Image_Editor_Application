import 'package:flutter/material.dart';

import '../../../../core/logging/app_logger.dart';
import '../../../../engine/color/exif_kelvin_reader.dart';
import '../../../../engine/history/history_state.dart';
import '../../../../engine/pipeline/edit_op_type.dart';
import '../../../../engine/pipeline/edit_pipeline.dart';
import '../../../../engine/pipeline/op_spec.dart';
import '../../../../engine/pipeline/pipeline_extensions.dart';
import '../../../../core/platform/haptics.dart';
import '../../../../core/theme/spacing.dart';
import '../notifiers/editor_session.dart';
import 'auto_section_button.dart';
import 'curves_sheet.dart';
import 'slider_row.dart';

final _log = AppLogger('LightroomPanel');

/// Lightroom-style categorized slider panel.
///
/// Specs are rendered in the order they appear in [OpSpecs.forCategory].
/// Sibling specs sharing a [OpSpec.group] value are rendered under a
/// section header; ungrouped specs render as plain sliders.
///
/// Thumb positions come from the committed pipeline (via [PipelineReaders])
/// so undo/redo immediately reflects in the UI.
class LightroomPanel extends StatelessWidget {
  const LightroomPanel({
    required this.category,
    required this.session,
    required this.state,
    super.key,
  });

  final OpCategory category;
  final EditorSession session;
  final HistoryState state;

  @override
  Widget build(BuildContext context) {
    final specs = OpSpecs.forCategory(category);
    if (specs.isEmpty) {
      return Padding(
        padding: const EdgeInsets.all(16),
        child: Text(
          '${category.label} — coming in a later phase',
          style: Theme.of(context).textTheme.bodyMedium,
        ),
      );
    }

    // Walk the specs in order and emit section headers when the group
    // changes.
    final children = <Widget>[];

    // Auto button for Light / Color panels — analyses the source image
    // and folds computed targets into this section's sliders.
    final autoScope = switch (category) {
      OpCategory.light => AutoFixScope.light,
      OpCategory.color => AutoFixScope.color,
      _ => null,
    };
    if (autoScope != null) {
      children.add(AutoSectionButton(
        session: session,
        scope: autoScope,
        includeWhiteBalance: category == OpCategory.color,
      ));
    }

    // Curves entry — only on the Light tab where it tonally fits.
    // The sheet authors a master curve (R/G/B per-channel ships in
    // a follow-up — the LUT baker already supports four rows).
    if (category == OpCategory.light) {
      children.add(_CurvesButton(session: session));
    }

    String? currentGroup;
    for (final spec in specs) {
      if (spec.group != currentGroup) {
        currentGroup = spec.group;
        if (currentGroup != null) {
          children.add(_SectionHeader(label: currentGroup));
        }
      }
      children.add(_buildSlider(spec, state.pipeline));
    }

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: children,
    );
  }

  Widget _buildSlider(OpSpec spec, EditPipeline pipeline) {
    final value = _valueFor(spec, pipeline);
    return SliderRow(
      key: ValueKey(
          '${spec.type}-${spec.paramKey}-${value.toStringAsFixed(4)}'),
      label: spec.label,
      description: spec.description,
      initialValue: value,
      min: spec.min,
      max: spec.max,
      identity: spec.identity,
      snapBand: spec.snapBand,
      formatValue: _formatter(spec),
      onChanged: (v) {
        _log.d('slider changed', {
          'type': spec.type,
          'paramKey': spec.paramKey,
          'value': v,
        });
        session.setScalar(spec.type, v, paramKey: spec.paramKey);
      },
      onChangeEnd: (_) => session.flushPendingCommit(),
    );
  }

  double _valueFor(OpSpec spec, EditPipeline pipeline) {
    // Fast-path common single-param ops via the named readers; fall back
    // to the generic readParam for multi-param ops.
    switch (spec.type) {
      case EditOpType.brightness:
        return pipeline.brightnessValue;
      case EditOpType.contrast:
        return pipeline.contrastValue;
      case EditOpType.exposure:
        return pipeline.exposureValue;
      case EditOpType.highlights:
        return pipeline.highlightsValue;
      case EditOpType.shadows:
        return pipeline.shadowsValue;
      case EditOpType.whites:
        return pipeline.whitesValue;
      case EditOpType.blacks:
        return pipeline.blacksValue;
      case EditOpType.temperature:
        return pipeline.temperatureValue;
      case EditOpType.tint:
        return pipeline.tintValue;
      case EditOpType.saturation:
        return pipeline.saturationValue;
      case EditOpType.vibrance:
        return pipeline.vibranceValue;
      case EditOpType.hue:
        return pipeline.hueValue;
      case EditOpType.dehaze:
        return pipeline.dehazeValue;
      case EditOpType.clarity:
        return pipeline.clarityValue;
    }
    return pipeline.readParam(spec.type, spec.paramKey, spec.identity);
  }

  String Function(double) _formatter(OpSpec spec) {
    if (spec.type == EditOpType.hue ||
        (spec.paramKey == 'angle' && spec.type != EditOpType.motionBlur)) {
      return (v) => '${v.toStringAsFixed(0)}°';
    }
    // XVI.31 — when the source EXIF says white-balance metadata is
    // present, switch the temperature slider's display from -1..+1 to
    // Kelvin pivoted on the recorded baseline (or D65 if the
    // makernote didn't include an explicit Kelvin). The op value
    // itself stays scalar so the shader path is untouched and pre-
    // XVI.31 saved pipelines round-trip identically.
    if (spec.type == EditOpType.temperature &&
        session.temperatureExif.mode == TemperatureMode.kelvin) {
      return (v) => formatTemperatureKelvin(
            v,
            session.temperatureExif.baselineKelvin,
          );
    }
    if (spec.paramKey == 'pixelSize' ||
        spec.paramKey == 'dotSize' ||
        spec.paramKey == 'cellSize' ||
        spec.paramKey == 'radius') {
      return (v) => v.toStringAsFixed(1);
    }
    return (v) => v.toStringAsFixed(2);
  }
}

/// XVI.31 — format the temperature slider's scalar value as a Kelvin
/// label. Public + free-function so widget tests don't have to spin
/// up an EditorSession.
///
/// Mirrors `whiteBalanceMultiplier` in `shaders/color_grading.frag`:
///   positive slider = warmer = lower Kelvin
///   negative slider = cooler = higher Kelvin
/// The shader's per-side multipliers (4500 for warm, 5500 for cool)
/// keep the slider's full travel inside the safe 2000..12000 K window
/// even after we pivot on a non-D65 baseline. We re-apply the same
/// multipliers here so the displayed Kelvin matches what the shader
/// will produce.
String formatTemperatureKelvin(double slider, double baselineKelvin) {
  final delta = slider >= 0 ? slider * 4500 : slider * 5500;
  final kelvin = (baselineKelvin - delta).clamp(2000.0, 12000.0);
  return '${kelvin.toStringAsFixed(0)} K';
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader({required this.label});
  final String label;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
      child: Text(
        label.toUpperCase(),
        style: theme.textTheme.labelSmall?.copyWith(
          color: theme.colorScheme.primary,
          letterSpacing: 1.2,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

/// Tonal-curve entry tile that lives at the top of the Light tab.
/// Opens the [CurvesSheet] modal and shows a small "active" badge
/// when a custom curve is committed so the user knows the panel
/// has hidden state.
class _CurvesButton extends StatelessWidget {
  const _CurvesButton({required this.session});
  final EditorSession session;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final hasCurve =
        session.committedPipeline.toneCurvePoints != null;
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: Spacing.lg,
        vertical: Spacing.xs,
      ),
      child: Material(
        color: hasCurve
            ? theme.colorScheme.primaryContainer
            : theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(10),
        child: InkWell(
          borderRadius: BorderRadius.circular(10),
          onTap: () {
            Haptics.tap();
            CurvesSheet.show(context, session);
          },
          child: Padding(
            padding: const EdgeInsets.all(Spacing.md),
            child: Row(
              children: [
                Icon(
                  Icons.show_chart,
                  color: hasCurve
                      ? theme.colorScheme.onPrimaryContainer
                      : theme.colorScheme.onSurfaceVariant,
                ),
                const SizedBox(width: Spacing.sm),
                Expanded(
                  child: Text(
                    hasCurve ? 'Tone curve · active' : 'Tone curve',
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: hasCurve
                          ? theme.colorScheme.onPrimaryContainer
                          : null,
                      fontWeight:
                          hasCurve ? FontWeight.w600 : FontWeight.normal,
                    ),
                  ),
                ),
                Icon(
                  Icons.chevron_right,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
