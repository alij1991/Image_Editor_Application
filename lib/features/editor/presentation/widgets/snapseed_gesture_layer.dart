import 'package:flutter/material.dart';

import '../../../../core/logging/app_logger.dart';
import '../../../../engine/pipeline/op_spec.dart';
import '../../../../engine/pipeline/pipeline_extensions.dart';
import '../notifiers/editor_session.dart';

final _log = AppLogger('SnapseedGesture');

/// Snapseed-style gesture layer: drag horizontally to adjust the current
/// parameter, drag vertically to cycle between parameters of the current
/// category. Shows a heads-up overlay while dragging.
///
/// Wrap the image canvas in one of these in the editor page. The layer
/// is transparent to taps and only reacts to drags.
class SnapseedGestureLayer extends StatefulWidget {
  const SnapseedGestureLayer({
    required this.session,
    required this.category,
    required this.child,
    super.key,
  });

  final EditorSession session;
  final OpCategory category;
  final Widget child;

  @override
  State<SnapseedGestureLayer> createState() => _SnapseedGestureLayerState();
}

class _SnapseedGestureLayerState extends State<SnapseedGestureLayer> {
  int _activeIndex = 0;
  double _accumulatedDx = 0;
  double _accumulatedDy = 0;
  double? _dragStartValue;
  bool _dragging = false;
  String? _hudLabel;
  double? _hudValue;

  List<OpSpec> get _specs => OpSpecs.forCategory(widget.category);

  OpSpec? get _activeSpec =>
      _specs.isEmpty ? null : _specs[_activeIndex % _specs.length];

  @override
  void didUpdateWidget(covariant SnapseedGestureLayer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.category != widget.category) {
      _activeIndex = 0;
    }
  }

  void _onVerticalUpdate(double dy) {
    // Vertical drags cycle through the category's specs; each full step
    // requires 48 px of travel to avoid accidental cycling.
    _accumulatedDy += dy;
    const threshold = 48.0;
    while (_accumulatedDy > threshold && _specs.isNotEmpty) {
      _accumulatedDy -= threshold;
      setState(() {
        _activeIndex = (_activeIndex + 1) % _specs.length;
      });
      _log.d('cycled down', {'index': _activeIndex});
    }
    while (_accumulatedDy < -threshold && _specs.isNotEmpty) {
      _accumulatedDy += threshold;
      setState(() {
        _activeIndex = (_activeIndex - 1 + _specs.length) % _specs.length;
      });
      _log.d('cycled up', {'index': _activeIndex});
    }
  }

  void _onHorizontalUpdate(double dx) {
    final spec = _activeSpec;
    if (spec == null) return;
    _accumulatedDx += dx;
    // Map 300 px of drag to the full [min, max] range.
    const pxForFullRange = 300.0;
    final range = spec.max - spec.min;
    final delta = (_accumulatedDx / pxForFullRange) * range;
    final start = _dragStartValue ?? 0.0;
    final next = (start + delta).clamp(spec.min, spec.max).toDouble();
    widget.session.setScalar(spec.type, next, paramKey: spec.paramKey);
    setState(() {
      _hudLabel = spec.label;
      _hudValue = next;
    });
  }

  void _onDragStart() {
    final spec = _activeSpec;
    if (spec == null) return;
    _dragStartValue = _currentValue(spec);
    _accumulatedDx = 0;
    _accumulatedDy = 0;
    _dragging = true;
    _log.d('drag start', {'type': spec.type, 'start': _dragStartValue});
  }

  void _onDragEnd() {
    _dragging = false;
    widget.session.flushPendingCommit();
    setState(() {
      _hudLabel = null;
      _hudValue = null;
    });
  }

  double _currentValue(OpSpec spec) {
    // Generic path — works for single-param AND multi-param ops. The
    // readParam helper falls back to the spec's identity if the op is
    // absent from the pipeline.
    return widget.session.committedPipeline
        .readParam(spec.type, spec.paramKey, spec.identity);
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        Positioned.fill(child: widget.child),
        Positioned.fill(
          child: GestureDetector(
            behavior: HitTestBehavior.translucent,
            onPanStart: (_) => _onDragStart(),
            onPanUpdate: (details) {
              // Classify per-frame delta: the dominant axis wins.
              final dx = details.delta.dx;
              final dy = details.delta.dy;
              if (dx.abs() > dy.abs()) {
                _onHorizontalUpdate(dx);
              } else {
                _onVerticalUpdate(dy);
              }
            },
            onPanEnd: (_) => _onDragEnd(),
            onPanCancel: _onDragEnd,
          ),
        ),
        if (_dragging && _hudLabel != null && _hudValue != null)
          Positioned(
            top: 16,
            left: 0,
            right: 0,
            child: Center(
              child: Material(
                color: Colors.black54,
                borderRadius: BorderRadius.circular(8),
                child: Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                  child: Text(
                    '$_hudLabel  ${_hudValue!.toStringAsFixed(2)}',
                    style: const TextStyle(color: Colors.white, fontSize: 14),
                  ),
                ),
              ),
            ),
          ),
        // Always-visible indicator of the active parameter when no drag.
        if (!_dragging && _activeSpec != null)
          Positioned(
            top: 16,
            right: 16,
            child: _ActiveIndicator(label: _activeSpec!.label),
          ),
      ],
    );
  }
}

class _ActiveIndicator extends StatelessWidget {
  const _ActiveIndicator({required this.label});
  final String label;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.black45,
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        child: Text(
          label,
          style: const TextStyle(color: Colors.white70, fontSize: 12),
        ),
      ),
    );
  }
}
