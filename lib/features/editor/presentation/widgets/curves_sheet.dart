import 'package:flutter/material.dart';

import '../../../../core/logging/app_logger.dart';
import '../../../../core/platform/haptics.dart';
import '../../../../core/theme/spacing.dart';
import '../../../../engine/color/curve.dart';
import '../../../../engine/pipeline/pipeline_extensions.dart';
import '../notifiers/editor_session.dart';

final _log = AppLogger('CurvesSheet');

/// Bottom sheet that exposes a draggable master tone curve. Tap a
/// segment to add a control point; drag any point to reshape the
/// curve; long-press a point to remove it. The endpoints (0,0) and
/// (1,1) are pinned so the curve always covers the full range.
///
/// Per-channel (R/G/B) curves land in a follow-up — the LUT baker
/// already handles four rows; this sheet only authors the master
/// row for now.
class CurvesSheet extends StatefulWidget {
  const CurvesSheet({required this.session, super.key});

  final EditorSession session;

  static Future<void> show(BuildContext context, EditorSession session) {
    _log.i('opened');
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (_) => CurvesSheet(session: session),
    );
  }

  @override
  State<CurvesSheet> createState() => _CurvesSheetState();
}

class _CurvesSheetState extends State<CurvesSheet> {
  late List<Offset> _points;

  @override
  void initState() {
    super.initState();
    final stored = widget.session.committedPipeline.toneCurvePoints;
    _points = stored != null
        ? [for (final p in stored) Offset(p[0], p[1])]
        : [const Offset(0, 0), const Offset(1, 1)];
  }

  void _commit() {
    final asPairs = [for (final p in _points) [p.dx, p.dy]];
    widget.session.setToneCurve(asPairs);
  }

  void _reset() {
    Haptics.tap();
    setState(() => _points = [const Offset(0, 0), const Offset(1, 1)]);
    widget.session.setToneCurve(null);
  }

  void _addPoint(Offset normalized) {
    Haptics.tap();
    setState(() {
      _points.add(normalized);
      _points.sort((a, b) => a.dx.compareTo(b.dx));
    });
    _commit();
  }

  void _movePoint(int i, Offset normalized) {
    setState(() {
      // Endpoints clamp to their respective edges so the curve
      // always covers [0..1] on the X axis.
      double x = normalized.dx;
      if (i == 0) {
        x = 0;
      } else if (i == _points.length - 1) {
        x = 1;
      } else {
        // Clamp between neighbours so the X order can never
        // invert mid-drag.
        final lo = _points[i - 1].dx + 0.005;
        final hi = _points[i + 1].dx - 0.005;
        x = x.clamp(lo, hi);
      }
      final y = normalized.dy.clamp(0.0, 1.0);
      _points[i] = Offset(x, y);
    });
  }

  void _removePoint(int i) {
    if (i == 0 || i == _points.length - 1) return; // endpoints pinned
    Haptics.impact();
    setState(() => _points.removeAt(i));
    _commit();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(Spacing.lg),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text('Tone curve', style: theme.textTheme.titleLarge),
                const Spacer(),
                IconButton(
                  tooltip: 'Reset',
                  icon: const Icon(Icons.restart_alt),
                  onPressed: _reset,
                ),
                IconButton(
                  tooltip: 'Close',
                  icon: const Icon(Icons.close),
                  onPressed: () => Navigator.of(context).pop(),
                ),
              ],
            ),
            const SizedBox(height: Spacing.xs),
            Text(
              'Tap to add a point. Drag to reshape. Long-press a '
              'middle point to remove it.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: Spacing.md),
            AspectRatio(
              aspectRatio: 1,
              child: _CurveEditor(
                points: _points,
                onAdd: _addPoint,
                onMove: _movePoint,
                onMoveEnd: _commit,
                onRemove: _removePoint,
              ),
            ),
            const SizedBox(height: Spacing.md),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                FilledButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text('Done'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// Square interactive surface that draws the curve and routes pointer
/// events to add / move / remove control points. Coordinates are
/// converted between local pixels and normalized [0..1] (Y is
/// inverted because (0,0) sits at the top-left of the canvas but
/// "low brightness" is at the bottom of the curve).
class _CurveEditor extends StatefulWidget {
  const _CurveEditor({
    required this.points,
    required this.onAdd,
    required this.onMove,
    required this.onMoveEnd,
    required this.onRemove,
  });

  final List<Offset> points;
  final ValueChanged<Offset> onAdd;
  final void Function(int index, Offset normalized) onMove;
  final VoidCallback onMoveEnd;
  final ValueChanged<int> onRemove;

  @override
  State<_CurveEditor> createState() => _CurveEditorState();
}

class _CurveEditorState extends State<_CurveEditor> {
  int? _activePoint;
  Size _box = Size.zero;
  static const double _kHitRadius = 24;

  Offset _toCanvas(Offset normalized) => Offset(
        normalized.dx * _box.width,
        (1.0 - normalized.dy) * _box.height,
      );

  Offset _toNormalized(Offset canvas) => Offset(
        canvas.dx / _box.width,
        1.0 - canvas.dy / _box.height,
      );

  int? _hitTest(Offset canvas) {
    for (int i = 0; i < widget.points.length; i++) {
      final p = _toCanvas(widget.points[i]);
      if ((p - canvas).distance <= _kHitRadius) return i;
    }
    return null;
  }

  void _onTapUp(TapUpDetails d) {
    final hit = _hitTest(d.localPosition);
    if (hit != null) return; // tap on existing point — ignore
    widget.onAdd(_toNormalized(d.localPosition));
  }

  void _onLongPressStart(LongPressStartDetails d) {
    final hit = _hitTest(d.localPosition);
    if (hit != null) widget.onRemove(hit);
  }

  void _onPanStart(DragStartDetails d) {
    _activePoint = _hitTest(d.localPosition);
    if (_activePoint != null) Haptics.tap();
  }

  void _onPanUpdate(DragUpdateDetails d) {
    if (_activePoint == null) return;
    widget.onMove(_activePoint!, _toNormalized(d.localPosition));
  }

  void _onPanEnd(DragEndDetails d) {
    if (_activePoint != null) {
      widget.onMoveEnd();
      _activePoint = null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return LayoutBuilder(
      builder: (context, constraints) {
        _box = constraints.biggest;
        return GestureDetector(
          onTapUp: _onTapUp,
          onLongPressStart: _onLongPressStart,
          onPanStart: _onPanStart,
          onPanUpdate: _onPanUpdate,
          onPanEnd: _onPanEnd,
          child: CustomPaint(
            painter: _CurvePainter(
              points: widget.points,
              accent: theme.colorScheme.primary,
              gridColor: theme.colorScheme.outlineVariant,
              fillColor: theme.colorScheme.surfaceContainerHighest,
            ),
            size: Size.infinite,
          ),
        );
      },
    );
  }
}

class _CurvePainter extends CustomPainter {
  _CurvePainter({
    required this.points,
    required this.accent,
    required this.gridColor,
    required this.fillColor,
  });

  final List<Offset> points;
  final Color accent;
  final Color gridColor;
  final Color fillColor;

  @override
  void paint(Canvas canvas, Size size) {
    // Background.
    canvas.drawRect(Offset.zero & size, Paint()..color = fillColor);

    // 4×4 grid (quarters + the diagonal-ish midpoints).
    final gridPaint = Paint()
      ..color = gridColor
      ..strokeWidth = 1;
    for (int i = 1; i < 4; i++) {
      final x = size.width * i / 4;
      final y = size.height * i / 4;
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), gridPaint);
      canvas.drawLine(Offset(0, y), Offset(size.width, y), gridPaint);
    }
    // Diagonal — the identity reference.
    canvas.drawLine(
      Offset(0, size.height),
      Offset(size.width, 0),
      Paint()
        ..color = gridColor.withValues(alpha: 0.6)
        ..strokeWidth = 1,
    );

    if (points.length < 2) return;
    final curve = ToneCurve([
      for (final p in points) CurvePoint(p.dx, p.dy),
    ]);

    final path = Path();
    const samples = 96;
    for (int i = 0; i <= samples; i++) {
      final x = i / samples;
      final y = curve.evaluate(x).clamp(0.0, 1.0);
      final px = x * size.width;
      final py = (1 - y) * size.height;
      if (i == 0) {
        path.moveTo(px, py);
      } else {
        path.lineTo(px, py);
      }
    }
    canvas.drawPath(
      path,
      Paint()
        ..color = accent
        ..strokeWidth = 2.5
        ..style = PaintingStyle.stroke
        ..isAntiAlias = true,
    );

    // Control point handles.
    final handleFill = Paint()..color = accent;
    final handleStroke = Paint()
      ..color = const Color(0xFFFFFFFF)
      ..strokeWidth = 2
      ..style = PaintingStyle.stroke;
    for (final p in points) {
      final c = Offset(p.dx * size.width, (1 - p.dy) * size.height);
      canvas.drawCircle(c, 7, handleFill);
      canvas.drawCircle(c, 7, handleStroke);
    }
  }

  @override
  bool shouldRepaint(covariant _CurvePainter old) {
    if (old.points.length != points.length) return true;
    for (int i = 0; i < points.length; i++) {
      if ((old.points[i] - points[i]).distanceSquared > 0) return true;
    }
    return old.accent != accent;
  }
}

