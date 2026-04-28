import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../../../../core/logging/app_logger.dart';
import '../../../../core/platform/haptics.dart';
import '../../../../core/theme/spacing.dart';
import '../../../../engine/geometry/guided_upright.dart';

final _log = AppLogger('GuidedUprightOverlay');

/// XVI.45 — full-screen modal that lets the user draw 2-4 guide
/// lines on the image. The solver inside the renderer derives a
/// homography from the lines that pulls the implied vanishing
/// points to infinity.
///
/// Interaction:
///
///   * Drag (touch-down → drag → release) draws one guide. The
///     line snaps to the drag endpoints; orientation is
///     auto-classified (mostly-horizontal vs mostly-vertical).
///   * Tap a guide's midpoint to remove it.
///   * Up to 4 guides; the 5th drag is ignored. Adding more lines
///     does not improve precision much past this — Lightroom Mobile
///     locks the same maximum.
///   * Apply commits via [onDone] with the final list. Cancel pops
///     without writing back.
///
/// Image coordinates are normalised to [0,1] of the displayed
/// image rect (same convention as the solver + the existing
/// crop_overlay).
class GuidedUprightOverlay extends StatefulWidget {
  const GuidedUprightOverlay({
    required this.source,
    required this.initial,
    required this.onDone,
    required this.onCancel,
    super.key,
  });

  final ui.Image source;

  /// Pre-existing guides — when the user reopens the modal we want
  /// to show the lines they previously authored. Empty list = fresh
  /// authoring.
  final List<GuidedUprightLine> initial;

  final ValueChanged<List<GuidedUprightLine>> onDone;
  final VoidCallback onCancel;

  @override
  State<GuidedUprightOverlay> createState() => _GuidedUprightOverlayState();
}

class _GuidedUprightOverlayState extends State<GuidedUprightOverlay> {
  static const int _kMaxLines = 4;
  static const double _kRemoveHitRadius = 24;

  late List<GuidedUprightLine> _lines;
  Offset? _dragStart;
  Offset? _dragCurrent;

  @override
  void initState() {
    super.initState();
    _lines = [...widget.initial];
  }

  // ---- Hit-testing for line removal ---------------------------------

  /// Index of the guide whose midpoint is within
  /// [_kRemoveHitRadius] pixels of [local], or null. Used by the
  /// tap-to-remove gesture.
  int? _hitMidpoint(Offset local, Size box) {
    for (var i = 0; i < _lines.length; i++) {
      final l = _lines[i];
      final mx = (l.x1 + l.x2) / 2 * box.width;
      final my = (l.y1 + l.y2) / 2 * box.height;
      final dx = local.dx - mx;
      final dy = local.dy - my;
      if (dx * dx + dy * dy <= _kRemoveHitRadius * _kRemoveHitRadius) {
        return i;
      }
    }
    return null;
  }

  // ---- Drag handling ------------------------------------------------

  void _onPanStart(DragStartDetails d, Size box) {
    if (_lines.length >= _kMaxLines) {
      Haptics.tap();
      return;
    }
    setState(() {
      _dragStart = d.localPosition;
      _dragCurrent = d.localPosition;
    });
  }

  void _onPanUpdate(DragUpdateDetails d, Size box) {
    if (_dragStart == null) return;
    setState(() => _dragCurrent = d.localPosition);
  }

  void _onPanEnd(DragEndDetails d, Size box) {
    if (_dragStart == null || _dragCurrent == null) {
      _dragStart = null;
      _dragCurrent = null;
      return;
    }
    final start = _dragStart!;
    final end = _dragCurrent!;
    setState(() {
      _dragStart = null;
      _dragCurrent = null;
    });
    final dx = (end.dx - start.dx).abs();
    final dy = (end.dy - start.dy).abs();
    // Reject very short drags — unintentional taps that would
    // produce degenerate lines.
    if (dx < 12 && dy < 12) return;
    if (_lines.length >= _kMaxLines) return;
    final w = box.width;
    final h = box.height;
    if (w <= 0 || h <= 0) return;
    final line = GuidedUprightLine(
      x1: (start.dx / w).clamp(0.0, 1.0),
      y1: (start.dy / h).clamp(0.0, 1.0),
      x2: (end.dx / w).clamp(0.0, 1.0),
      y2: (end.dy / h).clamp(0.0, 1.0),
    );
    _log.d('addLine', {'line': line.toQuad(), 'count': _lines.length + 1});
    Haptics.tap();
    setState(() => _lines = [..._lines, line]);
  }

  void _onTap(TapUpDetails d, Size box) {
    final hit = _hitMidpoint(d.localPosition, box);
    if (hit == null) return;
    Haptics.tap();
    _log.d('removeLine', {'index': hit});
    setState(() {
      _lines = [..._lines]..removeAt(hit);
    });
  }

  void _reset() {
    Haptics.tap();
    setState(() => _lines = const []);
  }

  // ---- Build --------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Material(
      color: Colors.black,
      child: SafeArea(
        child: Column(
          children: [
            _Toolbar(
              count: _lines.length,
              max: _kMaxLines,
              onReset: _lines.isEmpty ? null : _reset,
              onCancel: widget.onCancel,
              onDone: _lines.length >= 2
                  ? () {
                      _log.i('done', {'count': _lines.length});
                      Haptics.impact();
                      widget.onDone(List.unmodifiable(_lines));
                    }
                  : null,
            ),
            Expanded(
              child: Center(
                child: AspectRatio(
                  aspectRatio: widget.source.width / widget.source.height,
                  child: LayoutBuilder(
                    builder: (context, constraints) {
                      final box = constraints.biggest;
                      return GestureDetector(
                        onTapUp: (d) => _onTap(d, box),
                        onPanStart: (d) => _onPanStart(d, box),
                        onPanUpdate: (d) => _onPanUpdate(d, box),
                        onPanEnd: (d) => _onPanEnd(d, box),
                        child: Stack(
                          fit: StackFit.expand,
                          children: [
                            RawImage(image: widget.source, fit: BoxFit.fill),
                            CustomPaint(
                              painter: _GuidesPainter(
                                lines: _lines,
                                dragStart: _dragStart,
                                dragCurrent: _dragCurrent,
                                color: theme.colorScheme.primary,
                              ),
                              size: Size.infinite,
                            ),
                          ],
                        ),
                      );
                    },
                  ),
                ),
              ),
            ),
            _HelpFooter(count: _lines.length),
          ],
        ),
      ),
    );
  }
}

/// Top toolbar — reset, cancel, apply. Apply is disabled until at
/// least 2 lines exist (the solver requires that). Reset is hidden
/// when the line list is already empty.
class _Toolbar extends StatelessWidget {
  const _Toolbar({
    required this.count,
    required this.max,
    required this.onReset,
    required this.onCancel,
    required this.onDone,
  });

  final int count;
  final int max;
  final VoidCallback? onReset;
  final VoidCallback onCancel;
  final VoidCallback? onDone;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        Spacing.md,
        Spacing.sm,
        Spacing.md,
        Spacing.xs,
      ),
      child: Row(
        children: [
          IconButton(
            tooltip: 'Cancel',
            icon: const Icon(Icons.close, color: Colors.white),
            onPressed: onCancel,
          ),
          const Spacer(),
          Text(
            '$count / $max guides',
            style: const TextStyle(color: Colors.white70, fontSize: 13),
          ),
          const Spacer(),
          if (onReset != null)
            TextButton(
              onPressed: onReset,
              child: const Text('Reset'),
            ),
          IconButton(
            tooltip: onDone == null
                ? 'Draw at least two guide lines to apply'
                : 'Apply guided upright',
            icon: Icon(
              Icons.check,
              color: onDone == null ? Colors.white24 : Colors.white,
            ),
            onPressed: onDone,
          ),
        ],
      ),
    );
  }
}

/// Bottom helper text that nudges the user through the interaction.
class _HelpFooter extends StatelessWidget {
  const _HelpFooter({required this.count});
  final int count;

  @override
  Widget build(BuildContext context) {
    final text = switch (count) {
      0 => 'Drag along an edge that should be horizontal or vertical.',
      1 => 'Add at least one more guide to apply.',
      _ => 'Tap a line to remove it. Up to 4 guides total.',
    };
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        Spacing.lg,
        Spacing.sm,
        Spacing.lg,
        Spacing.md,
      ),
      child: Text(
        text,
        textAlign: TextAlign.center,
        style: const TextStyle(color: Colors.white70, fontSize: 12),
      ),
    );
  }
}

/// Paints the committed guides + the live drag preview.
class _GuidesPainter extends CustomPainter {
  _GuidesPainter({
    required this.lines,
    required this.dragStart,
    required this.dragCurrent,
    required this.color,
  });

  final List<GuidedUprightLine> lines;
  final Offset? dragStart;
  final Offset? dragCurrent;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final stroke = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2
      ..color = color;
    final shadow = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 4
      ..color = Colors.black.withValues(alpha: 0.5);
    final dot = Paint()
      ..style = PaintingStyle.fill
      ..color = color;
    final dotShadow = Paint()
      ..style = PaintingStyle.fill
      ..color = Colors.black.withValues(alpha: 0.6);

    for (final l in lines) {
      final p1 = Offset(l.x1 * size.width, l.y1 * size.height);
      final p2 = Offset(l.x2 * size.width, l.y2 * size.height);
      canvas.drawLine(p1, p2, shadow);
      canvas.drawLine(p1, p2, stroke);
      // Endpoints
      canvas.drawCircle(p1, 5, dotShadow);
      canvas.drawCircle(p1, 4, dot);
      canvas.drawCircle(p2, 5, dotShadow);
      canvas.drawCircle(p2, 4, dot);
      // Midpoint marker (the tap-to-remove hit zone)
      final mid = Offset((p1.dx + p2.dx) / 2, (p1.dy + p2.dy) / 2);
      canvas.drawCircle(mid, 8, dotShadow);
      canvas.drawCircle(mid, 6,
          Paint()..color = color.withValues(alpha: 0.6));
    }

    if (dragStart != null && dragCurrent != null) {
      final preview = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..color = color.withValues(alpha: 0.7);
      canvas.drawLine(dragStart!, dragCurrent!, shadow);
      canvas.drawLine(dragStart!, dragCurrent!, preview);
    }
  }

  @override
  bool shouldRepaint(covariant _GuidesPainter old) {
    return old.lines != lines ||
        old.dragStart != dragStart ||
        old.dragCurrent != dragCurrent ||
        old.color != color;
  }
}
