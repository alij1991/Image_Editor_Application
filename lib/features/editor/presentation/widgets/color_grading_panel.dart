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

final _log = AppLogger('ColorGradingPanel');

/// Phase XVI.27 — three-wheel Color Grading panel.
///
/// Mirrors the Lightroom Mobile Color Grading layout: four colour
/// "wheels" (Shadows / Midtones / Highlights / Global) plus a Balance
/// slider that shifts the midtone centre and a Blending slider that
/// scales the master strength. Each wheel is a tap-to-open
/// `ColorPicker` dialog (same pattern as [SplitToningPanel]) — the
/// hue + saturation the user picks is what the shader receives, so
/// the dialog is functionally a "wheel widget" even though we don't
/// custom-paint the literal disc.
///
/// Emits the whole map atomically through [EditorSession.setMapParams]
/// so a slider drag is one history entry instead of N.
class ColorGradingPanel extends StatelessWidget {
  const ColorGradingPanel({
    required this.session,
    required this.state,
    super.key,
  });

  final EditorSession session;
  final HistoryState state;

  void _updateColor({
    List<double>? shadow,
    List<double>? mid,
    List<double>? high,
    List<double>? global,
  }) {
    _update(
      shadow: shadow,
      mid: mid,
      high: high,
      global: global,
      balance: null,
      blending: null,
    );
  }

  void _updateBalance(double v) {
    _update(
      shadow: null,
      mid: null,
      high: null,
      global: null,
      balance: v,
      blending: null,
    );
  }

  void _updateBlending(double v) {
    _update(
      shadow: null,
      mid: null,
      high: null,
      global: null,
      balance: null,
      blending: v,
    );
  }

  void _update({
    required List<double>? shadow,
    required List<double>? mid,
    required List<double>? high,
    required List<double>? global,
    required double? balance,
    required double? blending,
  }) {
    final pipeline = state.pipeline;
    final shadowColor = shadow ?? pipeline.colorGradingShadowColor;
    final midColor = mid ?? pipeline.colorGradingMidColor;
    final highColor = high ?? pipeline.colorGradingHighColor;
    final globalColor = global ?? pipeline.colorGradingGlobalColor;
    final bal = balance ?? pipeline.colorGradingBalance;
    final bld = blending ?? pipeline.colorGradingBlending;
    _log.d('update', {
      'shadow': shadowColor,
      'mid': midColor,
      'high': highColor,
      'global': globalColor,
      'balance': bal,
      'blending': bld,
    });
    final colorsNeutral = _isNeutral(shadowColor) &&
        _isNeutral(midColor) &&
        _isNeutral(highColor) &&
        _isNeutral(globalColor);
    // Identity collapses the op so the chain stays short for untouched
    // photos. Two equivalent paths: every wheel neutral (no tint to
    // mix) OR blending == 0 (master mix kills any picked tint). Either
    // is a no-op; either should remove the op.
    final isIdentity = colorsNeutral || bld.abs() < 1e-3;
    session.setMapParams(
      EditOpType.colorGrading,
      {
        'shadowColor': shadowColor,
        'midColor': midColor,
        'highColor': highColor,
        'globalColor': globalColor,
        'balance': bal,
        'blending': bld,
      },
      removeIfIdentity: isIdentity,
    );
  }

  bool _isNeutral(List<double> rgb) {
    if (rgb.length != 3) return true;
    return (rgb[0] - 0.5).abs() < 1e-3 &&
        (rgb[1] - 0.5).abs() < 1e-3 &&
        (rgb[2] - 0.5).abs() < 1e-3;
  }

  void _reset() {
    _log.i('reset color grading');
    Haptics.tap();
    session.setMapParams(
      EditOpType.colorGrading,
      {
        'shadowColor': const [0.5, 0.5, 0.5],
        'midColor': const [0.5, 0.5, 0.5],
        'highColor': const [0.5, 0.5, 0.5],
        'globalColor': const [0.5, 0.5, 0.5],
        'balance': 0.0,
        'blending': 1.0,
      },
      removeIfIdentity: true,
    );
  }

  @override
  Widget build(BuildContext context) {
    final pipeline = state.pipeline;
    final shadow = pipeline.colorGradingShadowColor;
    final mid = pipeline.colorGradingMidColor;
    final high = pipeline.colorGradingHighColor;
    final global = pipeline.colorGradingGlobalColor;
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
                  'Tint shadows, mids, highlights and the whole image',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
              IconButton(
                tooltip: 'Reset color grading',
                icon: const Icon(Icons.restart_alt, size: 18),
                onPressed: _reset,
              ),
            ],
          ),
          const SizedBox(height: Spacing.sm),
          Text('Shadows', style: theme.textTheme.labelLarge),
          const SizedBox(height: Spacing.sm),
          _ColorRow(
            color: _rgbToColor(shadow),
            onChanged: (c) => _updateColor(shadow: _colorToRgb(c)),
          ),
          const SizedBox(height: Spacing.lg),
          Text('Midtones', style: theme.textTheme.labelLarge),
          const SizedBox(height: Spacing.sm),
          _ColorRow(
            color: _rgbToColor(mid),
            onChanged: (c) => _updateColor(mid: _colorToRgb(c)),
          ),
          const SizedBox(height: Spacing.lg),
          Text('Highlights', style: theme.textTheme.labelLarge),
          const SizedBox(height: Spacing.sm),
          _ColorRow(
            color: _rgbToColor(high),
            onChanged: (c) => _updateColor(high: _colorToRgb(c)),
          ),
          const SizedBox(height: Spacing.lg),
          Text('Global', style: theme.textTheme.labelLarge),
          const SizedBox(height: Spacing.sm),
          _ColorRow(
            color: _rgbToColor(global),
            onChanged: (c) => _updateColor(global: _colorToRgb(c)),
          ),
          const SizedBox(height: Spacing.lg),
          SliderRow(
            key: ValueKey(
                'cg-balance-${pipeline.colorGradingBalance.toStringAsFixed(3)}'),
            label: 'Balance',
            initialValue: pipeline.colorGradingBalance,
            min: -1,
            max: 1,
            description: 'Shifts the midpoint between shadows and highlights',
            onChanged: _updateBalance,
            onChangeEnd: (_) => session.flushPendingCommit(),
          ),
          const SizedBox(height: Spacing.sm),
          SliderRow(
            key: ValueKey(
                'cg-blending-${pipeline.colorGradingBlending.toStringAsFixed(3)}'),
            label: 'Blending',
            initialValue: pipeline.colorGradingBlending,
            min: 0,
            max: 1,
            description: 'Master strength of the colour tints',
            onChanged: _updateBlending,
            onChangeEnd: (_) => session.flushPendingCommit(),
          ),
        ],
      ),
    );
  }

  static Color _rgbToColor(List<double> rgb) {
    if (rgb.length != 3) return const Color(0xFF808080);
    int clampInt(double v) => (v * 255).round().clamp(0, 255);
    return Color.fromARGB(
        255, clampInt(rgb[0]), clampInt(rgb[1]), clampInt(rgb[2]));
  }

  static List<double> _colorToRgb(Color c) =>
      [c.r.toDouble(), c.g.toDouble(), c.b.toDouble()];
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
