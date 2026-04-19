import 'package:flutter/material.dart';

import '../../../../core/logging/app_logger.dart';
import '../../../../core/platform/haptics.dart';
import '../../../../engine/layers/content_layer.dart';
import '../../../../engine/pipeline/op_spec.dart';
import '../../../../engine/pipeline/pipeline_extensions.dart';
import '../controllers/viewport_transform_controller.dart';
import '../notifiers/editor_session.dart';
import 'layer_interaction.dart';

final _log = AppLogger('SnapseedGesture');

/// Snapseed-style gesture layer with pinch-zoom support.
///
/// Routing:
///   - 1 finger drag → current param slider (Snapseed horizontal /
///     vertical behaviour preserved).
///   - 2+ finger pinch / drag → pans and zooms the preview via
///     [ViewportTransformController].
///   - Double-tap → resets the viewport to identity.
///
/// Wrap the image canvas in one of these in the editor page. The layer
/// is transparent to taps and only reacts to drags / pinches.
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
  final ViewportTransformController _viewport = ViewportTransformController();
  final GlobalKey _canvasKey = GlobalKey();

  int _activeIndex = 0;
  double _accumulatedDx = 0;
  double _accumulatedDy = 0;
  double? _dragStartValue;
  bool _dragging = false;
  String? _hudLabel;
  double? _hudValue;

  // If we commit to a zoom gesture mid-stream (a second finger lands),
  // we stop feeding deltas to the Snapseed slider for the rest of the
  // gesture.
  bool _zoomMode = false;

  // When a layer is selected and the user drags/pinches starting on it,
  // we transform the layer rather than the viewport or the sliders.
  bool _layerMode = false;
  double _lastLayerScale = 1.0;
  double _lastLayerRotation = 0.0;

  /// True while the user long-presses the canvas to peek at the
  /// original photo. Drives the "Original" chip overlay + the
  /// `setAllOpsEnabledTransient(false)` on the session.
  bool _comparing = false;

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

  @override
  void dispose() {
    _viewport.dispose();
    super.dispose();
  }

  // ---- 1-finger Snapseed slider path -----------------------------------

  void _onVerticalUpdate(double dy) {
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

  void _beginSliderDrag() {
    final spec = _activeSpec;
    if (spec == null) return;
    _dragStartValue = _currentValue(spec);
    _accumulatedDx = 0;
    _accumulatedDy = 0;
    _dragging = true;
    _log.d('slider start', {'type': spec.type, 'start': _dragStartValue});
  }

  void _endSliderDrag() {
    _dragging = false;
    widget.session.flushPendingCommit();
    setState(() {
      _hudLabel = null;
      _hudValue = null;
    });
  }

  double _currentValue(OpSpec spec) {
    return widget.session.committedPipeline
        .readParam(spec.type, spec.paramKey, spec.identity);
  }

  // ---- Scale/pinch integration -----------------------------------------

  /// Return the live layer matching [id], or null if no such layer
  /// exists (e.g. just deleted).
  ContentLayer? _findLayer(String id) {
    final layers = widget.session.previewController.layers.value;
    for (final l in layers) {
      if (l.id == id) return l;
    }
    return null;
  }

  /// Map a viewport-coord point back into image-coord space so layer
  /// hit-tests work correctly when the user has zoomed the preview.
  /// The viewport matrix is `scale × s then translate by t`, so:
  ///   image = (viewport - t) / s
  Offset _toImageSpace(Offset viewport) {
    final s = _viewport.scale;
    final t = _viewport.translation;
    if (s == 1.0 && t == Offset.zero) return viewport;
    return Offset((viewport.dx - t.dx) / s, (viewport.dy - t.dy) / s);
  }

  /// Resolve the on-canvas size that the layer hit-test runs against.
  /// Falls back to the widget's context size when the key isn't
  /// attached yet (shouldn't happen once the first frame is painted).
  Size _canvasSize() {
    final box = _canvasKey.currentContext?.findRenderObject();
    if (box is RenderBox && box.hasSize) return box.size;
    final self = context.findRenderObject();
    if (self is RenderBox && self.hasSize) return self.size;
    return const Size(360, 640);
  }

  /// Resolve the top-most visible layer containing the gesture's
  /// local focal point, if any. Converts the viewport-space point into
  /// image space so it still hits the right layer when zoomed.
  LayerHit? _layerUnder(Offset local) {
    final layers = widget.session.previewController.layers.value;
    return hitTestLayers(
      layers: layers,
      local: _toImageSpace(local),
      canvasSize: _canvasSize(),
    );
  }

  void _onScaleStart(ScaleStartDetails d) {
    _layerMode = false;
    _zoomMode = false;

    final selectedId = widget.session.selectedLayerId.value;
    if (selectedId != null) {
      // If the user starts a gesture on the selected layer, route it
      // to the layer transform path — single-finger moves, two-finger
      // scales + rotates.
      final selected = _findLayer(selectedId);
      if (selected != null) {
        final bounds = boundsOfLayer(selected, _canvasSize());
        if (bounds != null &&
            bounds.contains(_toImageSpace(d.localFocalPoint))) {
          _layerMode = true;
          _lastLayerScale = 1.0;
          _lastLayerRotation = 0.0;
          _log.d('gesture start: layer transform', {'id': selected.id});
          return;
        }
      }
    }

    if (d.pointerCount >= 2) {
      _zoomMode = true;
      _viewport.beginGesture(d.focalPoint);
      _log.d('gesture start: pinch', {'pointers': d.pointerCount});
    } else {
      _beginSliderDrag();
    }
  }

  void _onScaleUpdate(ScaleUpdateDetails d) {
    if (_layerMode) {
      // Layer transform path. Drag delta is in viewport pixels; divide
      // by the viewport scale to get image-space pixels, then normalise
      // against the canvas size so the layer's (x, y) fields still mean
      // 0..1 of the image.
      final canvas = _canvasSize();
      final vs = _viewport.scale;
      final dxNorm = (d.focalPointDelta.dx / vs) / canvas.width;
      final dyNorm = (d.focalPointDelta.dy / vs) / canvas.height;
      final scaleDelta = d.scale / _lastLayerScale;
      final rotationDelta = d.rotation - _lastLayerRotation;
      _lastLayerScale = d.scale;
      _lastLayerRotation = d.rotation;
      widget.session.updateSelectedLayerTransform(
        dxNorm: dxNorm,
        dyNorm: dyNorm,
        scaleFactor: scaleDelta,
        dRotation: rotationDelta,
      );
      return;
    }

    // A second finger landed mid-gesture — cancel any in-flight slider
    // drag and flip into zoom mode.
    if (!_zoomMode && d.pointerCount >= 2) {
      _zoomMode = true;
      _endSliderDrag();
      _viewport.beginGesture(d.focalPoint);
      _log.d('promoted to pinch mid-gesture');
    }
    if (_zoomMode) {
      _viewport.updateGesture(
        scaleFactor: d.scale,
        focalPoint: d.focalPoint,
      );
      return;
    }
    // 1-finger path — classify per-frame delta.
    final dx = d.focalPointDelta.dx;
    final dy = d.focalPointDelta.dy;
    if (dx.abs() > dy.abs()) {
      _onHorizontalUpdate(dx);
    } else {
      _onVerticalUpdate(dy);
    }
  }

  void _onScaleEnd(ScaleEndDetails d) {
    if (_layerMode) {
      _log.d('gesture end: layer');
      _layerMode = false;
      widget.session.flushLayerTransform();
      return;
    }
    if (_zoomMode) {
      _log.d('gesture end: pinch', {
        'scale': _viewport.scale.toStringAsFixed(2),
      });
      _zoomMode = false;
      return;
    }
    _endSliderDrag();
  }

  void _onTapUp(TapUpDetails d) {
    // Tap on a layer selects it. Tap on empty canvas deselects.
    final hit = _layerUnder(d.localPosition);
    if (hit == null) {
      if (widget.session.selectedLayerId.value != null) {
        widget.session.selectLayer(null);
      }
      return;
    }
    widget.session.selectLayer(hit.layer.id);
  }

  // ---- Long-press-to-compare ---------------------------------------
  //
  // Holding a finger still on the canvas for ~500 ms flips every
  // color / fx / filter op off so the user sees the untouched source.
  // Releasing restores the edit. The Flutter gesture arena resolves
  // this cleanly against scale / double-tap: if the pointer moves
  // before the 500 ms threshold, the scale recogniser wins instead.
  void _onLongPressStart(LongPressStartDetails _) {
    if (_comparing) return;
    _log.i('compare: on');
    setState(() => _comparing = true);
    widget.session.setAllOpsEnabledTransient(false);
    Haptics.tap();
  }

  void _onLongPressEnd(LongPressEndDetails _) {
    if (!_comparing) return;
    _log.i('compare: off');
    widget.session.setAllOpsEnabledTransient(true);
    setState(() => _comparing = false);
    Haptics.tap();
  }

  void _onDoubleTapDown(TapDownDetails d) {
    // Double-tap toggles between identity and a 2x zoom on the tap
    // focal — mirrors Apple Photos / Instagram behaviour.
    if (_viewport.isIdentity) {
      _viewport.beginGesture(d.localPosition);
      _viewport.updateGesture(
        scaleFactor: 2.0,
        focalPoint: d.localPosition,
      );
      _log.i('double-tap: zoom to 2x');
    } else {
      _viewport.reset();
      _log.i('double-tap: reset');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      key: _canvasKey,
      children: [
        Positioned.fill(
          child: ClipRect(
            child: AnimatedBuilder(
              animation: _viewport,
              builder: (_, _) => Transform(
                transform: _viewport.value,
                // StackFit.expand is critical: with only Positioned.fill
                // children, a default loose Stack collapses to 0x0,
                // forcing ImageCanvas into a degenerate constraint and
                // breaking the shader renderer's toImageSync.
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    widget.child,
                    // Selection handles live inside the Transform so
                    // they scale + pan with the image under viewport
                    // zoom.
                    IgnorePointer(
                      child: _SelectionHandlesOverlay(
                        session: widget.session,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
        Positioned.fill(
          child: GestureDetector(
            behavior: HitTestBehavior.translucent,
            onScaleStart: _onScaleStart,
            onScaleUpdate: _onScaleUpdate,
            onScaleEnd: _onScaleEnd,
            onTapUp: _onTapUp,
            onDoubleTapDown: _onDoubleTapDown,
            // onDoubleTap handler is required for onDoubleTapDown to
            // fire (Flutter won't accept the recogniser otherwise).
            onDoubleTap: () {},
            onLongPressStart: _onLongPressStart,
            onLongPressEnd: _onLongPressEnd,
          ),
        ),
        // "Original" chip overlay — fades in when the user long-presses
        // to compare. Positioned top-left so it never covers the HUD
        // or the zoom chip.
        Positioned(
          top: 16,
          left: 16,
          child: IgnorePointer(
            child: AnimatedOpacity(
              opacity: _comparing ? 1.0 : 0.0,
              duration: const Duration(milliseconds: 150),
              child: Material(
                color: Colors.black.withValues(alpha: 0.65),
                borderRadius: BorderRadius.circular(8),
                child: const Padding(
                  padding: EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 6,
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.compare, size: 14, color: Colors.white),
                      SizedBox(width: 6),
                      Text(
                        'Original',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
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
                  padding: const EdgeInsets.symmetric(
                      horizontal: 12, vertical: 6),
                  child: Text(
                    '$_hudLabel  ${_hudValue!.toStringAsFixed(2)}',
                    style: const TextStyle(color: Colors.white, fontSize: 14),
                  ),
                ),
              ),
            ),
          ),
        // Zoom indicator — fades in whenever the viewport isn't at 1.0.
        // MUST stay wrapped in Positioned so the outer Stack treats it as
        // a positioned child; a bare AnimatedBuilder here would become
        // a non-positioned child and force the Stack to size to whatever
        // its builder returns (SizedBox.shrink → 0×0, collapsing the
        // whole canvas).
        Positioned(
          bottom: 16,
          left: 16,
          child: AnimatedBuilder(
            animation: _viewport,
            builder: (_, _) {
              if (_viewport.isIdentity) return const SizedBox.shrink();
              return _ZoomChip(
                scale: _viewport.scale,
                onReset: _viewport.reset,
              );
            },
          ),
        ),
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

/// Listens to [EditorSession.selectedLayerId] + the live content-layer
/// list and paints a fading dashed bounding box around the selected
/// layer. Animates in/out via AnimatedSwitcher.
class _SelectionHandlesOverlay extends StatelessWidget {
  const _SelectionHandlesOverlay({required this.session});
  final EditorSession session;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<String?>(
      valueListenable: session.selectedLayerId,
      builder: (context, selectedId, _) {
        if (selectedId == null) return const SizedBox.shrink();
        return ValueListenableBuilder<List<ContentLayer>>(
          valueListenable: session.previewController.layers,
          builder: (context, layers, _) {
            ContentLayer? selected;
            for (final l in layers) {
              if (l.id == selectedId) {
                selected = l;
                break;
              }
            }
            if (selected == null) return const SizedBox.shrink();
            // Bind to a local non-nullable so flow analysis carries
            // the promotion into the LayoutBuilder closure below.
            final ContentLayer layer = selected;
            final theme = Theme.of(context);
            return LayoutBuilder(
              builder: (ctx, constraints) {
                final size =
                    Size(constraints.maxWidth, constraints.maxHeight);
                final bounds = boundsOfLayer(layer, size);
                if (bounds == null) return const SizedBox.shrink();
                return AnimatedSwitcher(
                  duration: const Duration(milliseconds: 180),
                  child: CustomPaint(
                    key: ValueKey(layer.id),
                    size: size,
                    painter: LayerSelectionHandlesPainter(
                      bounds: bounds,
                      color: theme.colorScheme.primary,
                    ),
                  ),
                );
              },
            );
          },
        );
      },
    );
  }
}

class _ZoomChip extends StatelessWidget {
  const _ZoomChip({required this.scale, required this.onReset});
  final double scale;
  final VoidCallback onReset;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.black54,
      borderRadius: BorderRadius.circular(20),
      child: InkWell(
        borderRadius: BorderRadius.circular(20),
        onTap: onReset,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.zoom_in, size: 16, color: Colors.white),
              const SizedBox(width: 4),
              Text(
                '${scale.toStringAsFixed(1)}×  Reset',
                style: const TextStyle(color: Colors.white, fontSize: 12),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
