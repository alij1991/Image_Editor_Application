import 'package:flutter/material.dart';

import '../../../../core/logging/app_logger.dart';
import '../../../../core/platform/haptics.dart';
import '../../../../core/theme/spacing.dart';

final _log = AppLogger('SliderRow');

/// A single labeled slider for an adjustment parameter.
///
/// Uses a local [ValueNotifier] so drag updates never rebuild the parent
/// widget. A small identity tick is painted on the track at [identity]
/// so users can see where "no effect" is — matching Lightroom's slider
/// convention.
class SliderRow extends StatefulWidget {
  const SliderRow({
    required this.label,
    required this.initialValue,
    required this.onChanged,
    this.onChangeEnd,
    this.min = -1.0,
    this.max = 1.0,
    this.identity = 0.0,
    this.formatValue,
    this.description,
    super.key,
  });

  final String label;
  final double initialValue;
  final double min;
  final double max;
  final double identity;
  final ValueChanged<double> onChanged;
  final ValueChanged<double>? onChangeEnd;
  final String Function(double value)? formatValue;

  /// Optional tooltip/description that appears when the user long-presses
  /// the label — the primary in-UI guide for each adjustment.
  final String? description;

  @override
  State<SliderRow> createState() => _SliderRowState();
}

class _SliderRowState extends State<SliderRow> {
  late final ValueNotifier<double> _value;

  @override
  void initState() {
    super.initState();
    _value = ValueNotifier(widget.initialValue);
  }

  @override
  void didUpdateWidget(covariant SliderRow oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.initialValue != widget.initialValue) {
      _value.value = widget.initialValue;
    }
  }

  @override
  void dispose() {
    _value.dispose();
    super.dispose();
  }

  String _format(double v) {
    if (widget.formatValue != null) return widget.formatValue!(v);
    return v.toStringAsFixed(2);
  }

  void _reset() {
    _log.i('reset', {'label': widget.label, 'identity': widget.identity});
    Haptics.tap();
    _value.value = widget.identity;
    widget.onChanged(widget.identity);
    widget.onChangeEnd?.call(widget.identity);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final labelChild = Text(
      widget.label,
      style: theme.textTheme.titleSmall,
    );
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: Spacing.lg,
        vertical: Spacing.sm,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Expanded(
                child: widget.description != null
                    ? Tooltip(
                        message: widget.description!,
                        triggerMode: TooltipTriggerMode.longPress,
                        waitDuration: const Duration(milliseconds: 300),
                        child: labelChild,
                      )
                    : labelChild,
              ),
              ValueListenableBuilder<double>(
                valueListenable: _value,
                builder: (context, v, _) {
                  return Text(
                    _format(v),
                    style: theme.textTheme.bodySmall?.copyWith(
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  );
                },
              ),
              const SizedBox(width: Spacing.xs),
              IconButton(
                tooltip: 'Reset ${widget.label}',
                icon: const Icon(Icons.restart_alt, size: 18),
                onPressed: _reset,
              ),
            ],
          ),
          _SliderWithIdentityTick(
            value: _value,
            min: widget.min,
            max: widget.max,
            identity: widget.identity,
            onChanged: widget.onChanged,
            onChangeEnd: widget.onChangeEnd,
            format: _format,
          ),
        ],
      ),
    );
  }
}

/// Slider with a subtle tick mark painted at the identity position.
class _SliderWithIdentityTick extends StatelessWidget {
  const _SliderWithIdentityTick({
    required this.value,
    required this.min,
    required this.max,
    required this.identity,
    required this.onChanged,
    required this.onChangeEnd,
    required this.format,
  });

  final ValueNotifier<double> value;
  final double min;
  final double max;
  final double identity;
  final ValueChanged<double> onChanged;
  final ValueChanged<double>? onChangeEnd;
  final String Function(double) format;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return LayoutBuilder(
      builder: (context, constraints) {
        // Slider's horizontal padding is 24 px on each side by default
        // (for the thumb overlay). The tick lives in the track's
        // coordinate space.
        const horizontalPadding = 24.0;
        final trackWidth = constraints.maxWidth - horizontalPadding * 2;
        final t = ((identity - min) / (max - min)).clamp(0.0, 1.0);
        final tickX = horizontalPadding + t * trackWidth;
        return SizedBox(
          height: 40,
          child: Stack(
            alignment: Alignment.center,
            children: [
              Positioned(
                left: tickX - 1,
                top: 13,
                bottom: 13,
                child: Container(
                  width: 2,
                  decoration: BoxDecoration(
                    color: theme.colorScheme.outline.withValues(alpha: 0.7),
                    borderRadius: BorderRadius.circular(1),
                  ),
                ),
              ),
              ValueListenableBuilder<double>(
                valueListenable: value,
                builder: (context, v, _) {
                  return Slider(
                    value: v.clamp(min, max),
                    min: min,
                    max: max,
                    label: format(v),
                    onChanged: (next) {
                      value.value = next;
                      onChanged(next);
                    },
                    onChangeEnd: onChangeEnd,
                  );
                },
              ),
            ],
          ),
        );
      },
    );
  }
}
