import 'package:flutter/material.dart';
import 'package:flutter_colorpicker/flutter_colorpicker.dart';

import '../../../../core/logging/app_logger.dart';
import '../../../../core/platform/haptics.dart';
import '../../../../core/theme/spacing.dart';
import '../../../../engine/history/history_state.dart';
import '../../../../engine/pipeline/edit_op_type.dart';
import '../../../../engine/pipeline/pipeline_extensions.dart';
import '../notifiers/editor_session.dart';
import 'slider_row.dart';

final _log = AppLogger('SplitTonePanel');

/// Split toning controls: two color pickers (highlights + shadows) and a
/// balance slider that shifts the midpoint. Emits a single multi-param
/// op via [EditorSession.setMapParams].
class SplitToningPanel extends StatelessWidget {
  const SplitToningPanel({
    required this.session,
    required this.state,
    super.key,
  });

  final EditorSession session;
  final HistoryState state;

  void _updateHighlight(Color c) {
    _update(
      hi: [c.r.toDouble(), c.g.toDouble(), c.b.toDouble()],
      lo: null,
      balance: null,
    );
  }

  void _updateShadow(Color c) {
    _update(
      hi: null,
      lo: [c.r.toDouble(), c.g.toDouble(), c.b.toDouble()],
      balance: null,
    );
  }

  void _updateBalance(double v) {
    _update(hi: null, lo: null, balance: v);
  }

  void _update({
    List<double>? hi,
    List<double>? lo,
    double? balance,
  }) {
    final pipeline = state.pipeline;
    final hiColor = hi ?? pipeline.splitHighlightColor;
    final loColor = lo ?? pipeline.splitShadowColor;
    final bal = balance ?? pipeline.splitBalance;
    _log.d('update', {
      'hi': hiColor,
      'lo': loColor,
      'balance': bal,
    });
    final isNeutral = _isNeutral(hiColor) && _isNeutral(loColor) && bal == 0;
    session.setMapParams(
      EditOpType.splitToning,
      {'hiColor': hiColor, 'loColor': loColor, 'balance': bal},
      removeIfIdentity: isNeutral,
    );
  }

  bool _isNeutral(List<double> rgb) {
    if (rgb.length != 3) return true;
    return (rgb[0] - 0.5).abs() < 1e-3 &&
        (rgb[1] - 0.5).abs() < 1e-3 &&
        (rgb[2] - 0.5).abs() < 1e-3;
  }

  void _reset() {
    _log.i('reset split toning');
    Haptics.tap();
    session.setMapParams(
      EditOpType.splitToning,
      {
        'hiColor': const [0.5, 0.5, 0.5],
        'loColor': const [0.5, 0.5, 0.5],
        'balance': 0.0,
      },
      removeIfIdentity: true,
    );
  }

  @override
  Widget build(BuildContext context) {
    final pipeline = state.pipeline;
    final hi = pipeline.splitHighlightColor;
    final lo = pipeline.splitShadowColor;
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: Spacing.lg,
        vertical: Spacing.sm,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  'Tint highlights and shadows independently',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
              IconButton(
                tooltip: 'Reset split toning',
                icon: const Icon(Icons.restart_alt, size: 18),
                onPressed: _reset,
              ),
            ],
          ),
          const SizedBox(height: Spacing.sm),
          Text('Highlights', style: theme.textTheme.labelLarge),
          const SizedBox(height: Spacing.sm),
          _ColorRow(
            color: _rgbToColor(hi),
            onChanged: _updateHighlight,
          ),
          const SizedBox(height: Spacing.lg),
          Text('Shadows', style: theme.textTheme.labelLarge),
          const SizedBox(height: Spacing.sm),
          _ColorRow(
            color: _rgbToColor(lo),
            onChanged: _updateShadow,
          ),
          const SizedBox(height: Spacing.lg),
          SliderRow(
            key: ValueKey(
                'split-balance-${pipeline.splitBalance.toStringAsFixed(3)}'),
            label: 'Balance',
            initialValue: pipeline.splitBalance,
            min: -1,
            max: 1,
            description:
                'Shifts the midpoint between highlights and shadows tinting',
            onChanged: _updateBalance,
            onChangeEnd: (_) => session.flushPendingCommit(),
          ),
        ],
      ),
    );
  }

  static Color _rgbToColor(List<double> rgb) {
    if (rgb.length != 3) return const Color(0xFF808080);
    int clamp(double v) => (v * 255).round().clamp(0, 255);
    return Color.fromARGB(255, clamp(rgb[0]), clamp(rgb[1]), clamp(rgb[2]));
  }
}

String _hexFor(Color c) {
  String toHex(double channel) =>
      (channel * 255).round().clamp(0, 255).toRadixString(16).padLeft(2, '0');
  return '#${toHex(c.r)}${toHex(c.g)}${toHex(c.b)}';
}

class _ColorRow extends StatelessWidget {
  const _ColorRow({required this.color, required this.onChanged});
  final Color color;
  final ValueChanged<Color> onChanged;

  Future<void> _pick(BuildContext context) async {
    _log.i('color dialog open');
    Color current = color;
    await showDialog<void>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('Pick a tint'),
          content: SingleChildScrollView(
            child: ColorPicker(
              pickerColor: current,
              onColorChanged: (c) => current = c,
              enableAlpha: false,
              labelTypes: const [],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () {
                _log.i('color dialog cancelled');
                Navigator.of(context).pop();
              },
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () {
                _log.i('color picked', {
                  'r': current.r,
                  'g': current.g,
                  'b': current.b,
                });
                Haptics.tap();
                onChanged(current);
                Navigator.of(context).pop();
              },
              child: const Text('Pick'),
            ),
          ],
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        InkWell(
          onTap: () => _pick(context),
          borderRadius: BorderRadius.circular(8),
          child: Container(
            width: 56,
            height: 32,
            decoration: BoxDecoration(
              color: color,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(
                color: Theme.of(context).colorScheme.outline,
              ),
            ),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Text(
            _hexFor(color),
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ),
        TextButton(
          onPressed: () => _pick(context),
          child: const Text('Change'),
        ),
      ],
    );
  }
}
