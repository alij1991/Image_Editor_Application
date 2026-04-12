import 'package:flutter/material.dart';

import '../../../../core/logging/app_logger.dart';
import '../../../../engine/history/history_state.dart';
import '../../../../engine/pipeline/edit_op_type.dart';
import '../../../../engine/pipeline/edit_pipeline.dart';
import '../../../../engine/pipeline/op_spec.dart';
import '../../../../engine/pipeline/pipeline_extensions.dart';
import '../notifiers/editor_session.dart';
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
    if (spec.paramKey == 'pixelSize' ||
        spec.paramKey == 'dotSize' ||
        spec.paramKey == 'cellSize' ||
        spec.paramKey == 'radius') {
      return (v) => v.toStringAsFixed(1);
    }
    return (v) => v.toStringAsFixed(2);
  }
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
