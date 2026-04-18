import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_colorpicker/flutter_colorpicker.dart';

import '../../../../core/logging/app_logger.dart';
import '../../../../core/platform/haptics.dart';
import '../../../../core/theme/spacing.dart';
import '../../../../engine/layers/content_layer.dart';
import '../../../../engine/pipeline/geometry_state.dart';

final _log = AppLogger('DrawModeOverlay');

/// Modal draw-mode overlay. When active, intercepts all pointer drags
/// on the canvas, accumulates strokes, and on "Done" returns a
/// [DrawingLayer] for the session to append.
///
/// Rendering order:
///   - background: the source photo (un-rotated)
///   - foreground: the live stroke painter
///
/// Coordinates are normalized (0..1) to the source's un-rotated rect so
/// drawings compose correctly with the geometry chain in the main
/// editor. When the image has a non-identity rotation/flip, a hint
/// banner explains that the user is drawing on the original orientation.
class DrawModeOverlay extends StatefulWidget {
  const DrawModeOverlay({
    required this.source,
    required this.onDone,
    required this.onCancel,
    required this.newLayerId,
    this.geometry = GeometryState.identity,
    super.key,
  });

  final ui.Image source;

  /// The editor's current geometry. Only used to decide whether to show
  /// the "drawing on original orientation" banner.
  final GeometryState geometry;

  /// Called with the finished [DrawingLayer] when the user taps Done.
  final ValueChanged<DrawingLayer> onDone;

  /// Called when the user taps Cancel without saving strokes.
  final VoidCallback onCancel;

  /// Id to stamp on the new layer (generate via Uuid in the caller).
  final String newLayerId;

  @override
  State<DrawModeOverlay> createState() => _DrawModeOverlayState();
}

class _DrawModeOverlayState extends State<DrawModeOverlay> {
  final List<DrawingStroke> _strokes = [];
  final ValueNotifier<List<DrawingStroke>> _liveStrokes = ValueNotifier([]);

  List<StrokePoint>? _activePoints;
  Size _canvasSize = Size.zero;
  Color _color = Colors.white;
  double _width = 6.0;
  double _opacity = 1.0;
  double _hardness = 1.0;
  DrawingBrushType _brushType = DrawingBrushType.pen;

  @override
  void initState() {
    super.initState();
    _log.i('enter', {
      'layerId': widget.newLayerId,
      'geometry': widget.geometry.toString(),
    });
  }

  @override
  void dispose() {
    _liveStrokes.dispose();
    super.dispose();
  }

  void _onPanStart(Offset local) {
    if (_canvasSize.isEmpty) return;
    _activePoints = [
      StrokePoint(
          local.dx / _canvasSize.width, local.dy / _canvasSize.height),
    ];
    _pushLive();
    _log.d('stroke start', {'x': local.dx, 'y': local.dy});
  }

  void _onPanUpdate(Offset local) {
    if (_activePoints == null || _canvasSize.isEmpty) return;
    _activePoints!.add(
      StrokePoint(
          local.dx / _canvasSize.width, local.dy / _canvasSize.height),
    );
    _pushLive();
  }

  void _onPanEnd() {
    if (_activePoints == null) return;
    _strokes.add(
      DrawingStroke(
        points: List.unmodifiable(_activePoints!),
        colorArgb: _color.toARGB32(),
        width: _width,
        opacity: _opacity,
        hardness: _hardness,
        brushType: _brushType,
      ),
    );
    _activePoints = null;
    _pushLive();
    _log.d('stroke end', {'total': _strokes.length});
  }

  void _pushLive() {
    final live = [
      ..._strokes,
      if (_activePoints != null && _activePoints!.isNotEmpty)
        DrawingStroke(
          points: List.unmodifiable(_activePoints!),
          colorArgb: _color.toARGB32(),
          width: _width,
        ),
    ];
    _liveStrokes.value = live;
  }

  void _undo() {
    if (_strokes.isEmpty) return;
    _log.i('undo stroke');
    Haptics.tap();
    _strokes.removeLast();
    _pushLive();
  }

  void _clear() {
    if (_strokes.isEmpty) return;
    _log.i('clear all strokes');
    Haptics.impact();
    _strokes.clear();
    _pushLive();
  }

  Future<void> _pickColor() async {
    _log.i('color dialog open');
    Color current = _color;
    final picked = await showDialog<Color>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Brush color'),
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
              _log.i('color picked', {'argb': current.toARGB32()});
              Navigator.of(context).pop(current);
            },
            child: const Text('Pick'),
          ),
        ],
      ),
    );
    if (picked != null) {
      setState(() => _color = picked);
    }
  }

  void _save() {
    _log.i('save drawing', {'strokes': _strokes.length});
    Haptics.impact();
    if (_strokes.isEmpty) {
      widget.onCancel();
      return;
    }
    widget.onDone(
      DrawingLayer(
        id: widget.newLayerId,
        strokes: List.unmodifiable(_strokes),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final showRotationHint = !widget.geometry.isIdentity;
    return Column(
      children: [
        // Canvas area: source image behind, live strokes in front.
        Expanded(
          child: Padding(
            padding: const EdgeInsets.all(Spacing.md),
            child: Column(
              children: [
                if (showRotationHint) const _RotationHintBanner(),
                Expanded(
                  child: Center(
                    child: AspectRatio(
                      aspectRatio: widget.source.width / widget.source.height,
                      child: ClipRect(
                        child: LayoutBuilder(
                          builder: (context, constraints) {
                            _canvasSize = Size(
                              constraints.maxWidth,
                              constraints.maxHeight,
                            );
                            return GestureDetector(
                              behavior: HitTestBehavior.opaque,
                              onPanStart: (d) =>
                                  _onPanStart(d.localPosition),
                              onPanUpdate: (d) =>
                                  _onPanUpdate(d.localPosition),
                              onPanEnd: (_) => _onPanEnd(),
                              onPanCancel: _onPanEnd,
                              child: Stack(
                                fit: StackFit.expand,
                                children: [
                                  // Background: the source image.
                                  RawImage(
                                    image: widget.source,
                                    fit: BoxFit.contain,
                                  ),
                                  // Foreground: live strokes.
                                  ValueListenableBuilder<List<DrawingStroke>>(
                                    valueListenable: _liveStrokes,
                                    builder: (context, strokes, _) {
                                      return CustomPaint(
                                        painter: _LiveStrokesPainter(
                                          strokes: strokes,
                                        ),
                                        size: Size.infinite,
                                      );
                                    },
                                  ),
                                ],
                              ),
                            );
                          },
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
        // Toolbar.
        Container(
          color: theme.colorScheme.surfaceContainerHighest,
          padding: const EdgeInsets.all(Spacing.md),
          child: SafeArea(
            top: false,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // Brush type chips: pen / marker / spray. Each is a
                // tiny tap target with an icon so the user can scan
                // the row at a glance.
                Wrap(
                  spacing: Spacing.xs,
                  children: [
                    _BrushChip(
                      label: 'Pen',
                      icon: Icons.edit,
                      selected: _brushType == DrawingBrushType.pen,
                      onTap: () =>
                          setState(() => _brushType = DrawingBrushType.pen),
                    ),
                    _BrushChip(
                      label: 'Marker',
                      icon: Icons.brush,
                      selected: _brushType == DrawingBrushType.marker,
                      onTap: () => setState(
                          () => _brushType = DrawingBrushType.marker),
                    ),
                    _BrushChip(
                      label: 'Spray',
                      icon: Icons.scatter_plot_outlined,
                      selected: _brushType == DrawingBrushType.spray,
                      onTap: () => setState(
                          () => _brushType = DrawingBrushType.spray),
                    ),
                  ],
                ),
                const SizedBox(height: Spacing.xs),
                Row(
                  children: [
                    Tooltip(
                      message: 'Pick color',
                      child: InkWell(
                        onTap: _pickColor,
                        borderRadius: BorderRadius.circular(8),
                        child: Container(
                          width: 40,
                          height: 40,
                          decoration: BoxDecoration(
                            color: _color,
                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(
                              color: theme.colorScheme.outline,
                            ),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: Spacing.md),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Brush: ${_width.round()} px',
                            style: theme.textTheme.labelMedium,
                          ),
                          Slider(
                            value: _width,
                            min: 1,
                            max: 60,
                            onChanged: (v) => setState(() => _width = v),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                Row(
                  children: [
                    Expanded(
                      child: _MiniSlider(
                        label: 'Opacity',
                        value: _opacity,
                        valueLabel: '${(_opacity * 100).round()}%',
                        onChanged: (v) => setState(() => _opacity = v),
                      ),
                    ),
                    const SizedBox(width: Spacing.md),
                    Expanded(
                      child: _MiniSlider(
                        // Spray is naturally soft; the hardness slider
                        // is hidden for it to avoid surfacing a
                        // control that has no visible effect.
                        label: 'Hardness',
                        value: _hardness,
                        valueLabel: '${(_hardness * 100).round()}%',
                        onChanged: _brushType == DrawingBrushType.spray
                            ? null
                            : (v) => setState(() => _hardness = v),
                      ),
                    ),
                  ],
                ),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: [
                    IconButton.filledTonal(
                      tooltip: 'Undo last stroke',
                      icon: const Icon(Icons.undo),
                      onPressed: _strokes.isEmpty ? null : _undo,
                    ),
                    IconButton.filledTonal(
                      tooltip: 'Clear all',
                      icon: const Icon(Icons.delete_outline),
                      onPressed: _strokes.isEmpty ? null : _clear,
                    ),
                    TextButton(
                      onPressed: () {
                        _log.i('cancel');
                        widget.onCancel();
                      },
                      child: const Text('Cancel'),
                    ),
                    FilledButton.icon(
                      icon: const Icon(Icons.check),
                      label: const Text('Done'),
                      onPressed: _save,
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _RotationHintBanner extends StatelessWidget {
  const _RotationHintBanner();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      margin: const EdgeInsets.only(bottom: Spacing.sm),
      padding: const EdgeInsets.symmetric(
        horizontal: Spacing.md,
        vertical: Spacing.sm,
      ),
      decoration: BoxDecoration(
        color: theme.colorScheme.tertiaryContainer,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: [
          Icon(
            Icons.info_outline,
            size: 18,
            color: theme.colorScheme.onTertiaryContainer,
          ),
          const SizedBox(width: Spacing.sm),
          Expanded(
            child: Text(
              "You're drawing on the original orientation. Rotation and flips will apply after.",
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onTertiaryContainer,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _LiveStrokesPainter extends CustomPainter {
  _LiveStrokesPainter({required this.strokes});
  final List<DrawingStroke> strokes;

  @override
  void paint(ui.Canvas canvas, ui.Size size) {
    for (final stroke in strokes) {
      if (stroke.points.isEmpty) continue;
      final paint = Paint()
        ..color = Color(stroke.colorArgb)
        ..strokeWidth = stroke.width
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round
        ..style = PaintingStyle.stroke
        ..isAntiAlias = true;
      if (stroke.points.length == 1) {
        final p = stroke.points.first;
        canvas.drawCircle(
          Offset(p.x * size.width, p.y * size.height),
          stroke.width / 2,
          Paint()..color = Color(stroke.colorArgb),
        );
        continue;
      }
      final path = Path();
      final first = stroke.points.first;
      path.moveTo(first.x * size.width, first.y * size.height);
      for (int i = 1; i < stroke.points.length; i++) {
        final p = stroke.points[i];
        path.lineTo(p.x * size.width, p.y * size.height);
      }
      canvas.drawPath(path, paint);
    }
  }

  @override
  bool shouldRepaint(covariant _LiveStrokesPainter oldDelegate) =>
      oldDelegate.strokes != strokes;
}

/// Compact chip for picking a brush type. Selected state lights up
/// the surface with the primary container colour so the active
/// choice is unambiguous from across the room.
class _BrushChip extends StatelessWidget {
  const _BrushChip({
    required this.label,
    required this.icon,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final IconData icon;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final fg = selected
        ? theme.colorScheme.onPrimaryContainer
        : theme.colorScheme.onSurfaceVariant;
    final bg = selected
        ? theme.colorScheme.primaryContainer
        : theme.colorScheme.surfaceContainerLow;
    return Material(
      color: bg,
      borderRadius: BorderRadius.circular(20),
      child: InkWell(
        borderRadius: BorderRadius.circular(20),
        onTap: () {
          Haptics.tap();
          onTap();
        },
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: Spacing.md,
            vertical: Spacing.xs,
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 16, color: fg),
              const SizedBox(width: Spacing.xs),
              Text(
                label,
                style: theme.textTheme.labelMedium?.copyWith(color: fg),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Two-line slider used for the opacity / hardness controls. The
/// label sits above the slider with a right-aligned value readout.
/// Disabled state (null onChanged) greys both ends.
class _MiniSlider extends StatelessWidget {
  const _MiniSlider({
    required this.label,
    required this.value,
    required this.valueLabel,
    required this.onChanged,
  });

  final String label;
  final double value;
  final String valueLabel;
  final ValueChanged<double>? onChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final disabled = onChanged == null;
    final color = disabled
        ? theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.5)
        : null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          children: [
            Text(
              label,
              style: theme.textTheme.labelMedium?.copyWith(color: color),
            ),
            const Spacer(),
            Text(
              valueLabel,
              style: theme.textTheme.labelSmall?.copyWith(
                color: color ?? theme.colorScheme.onSurfaceVariant,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
          ],
        ),
        Slider(
          value: value.clamp(0.0, 1.0),
          min: 0,
          max: 1,
          onChanged: onChanged,
        ),
      ],
    );
  }
}
