import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../../../../core/logging/app_logger.dart';
import '../../../../core/platform/haptics.dart';
import '../../../../core/theme/spacing.dart';

final _log = AppLogger('InpaintBrush');

/// Result handed to [InpaintBrushOverlay.onDone] when the user
/// commits a mask. [maskPng] is a single-channel PNG sized to the
/// source image where white = "remove this", black = "keep". The
/// LaMa scaffold consumes it via `InpaintService.inpaint(...)`.
class InpaintBrushResult {
  InpaintBrushResult({required this.maskPng, required this.sourcePath});
  final Uint8List maskPng;
  final String sourcePath;
}

/// One brush stroke captured during the paint session. Stored as a
/// list of pointer positions in canvas coordinates (we resample to
/// source coordinates only when the user commits, so the working
/// stroke list is cheap to manipulate during undo / redo).
class _InpaintStroke {
  _InpaintStroke({
    required this.points,
    required this.radius,
    required this.erase,
  });
  final List<Offset> points;
  final double radius;
  final bool erase;
}

/// Full-screen overlay that lets the user paint a soft mask of the
/// region they want LaMa to fill. Modeled after Snapseed's "Healing"
/// brush:
///   - Drag → paint white into the mask.
///   - Toggle to eraser → drag removes from the mask.
///   - Adjustable brush radius (slider at the top).
///   - Undo / clear in the top bar.
///   - Mask renders as a translucent red overlay on the source so
///     the user sees exactly what they're targeting.
///   - Done → encodes the mask to PNG at source resolution and
///     hands it to [onDone]. Cancel pops without firing.
///
/// The widget owns its own ui.Image of the source so it can render
/// the underlay without going through the editor's preview proxy. It
/// disposes the image on tear-down.
///
/// **Status**: UI is fully wired and ready. The [InpaintService]
/// scaffold currently throws "model not yet available" — the moment
/// the LaMa runtime is wired, the overlay's [onDone] callback flows
/// directly into the service's `inpaint(...)` call.
class InpaintBrushOverlay extends StatefulWidget {
  const InpaintBrushOverlay({
    required this.source,
    required this.sourcePath,
    required this.onDone,
    required this.onCancel,
    super.key,
  });

  final ui.Image source;
  final String sourcePath;
  final ValueChanged<InpaintBrushResult> onDone;
  final VoidCallback onCancel;

  @override
  State<InpaintBrushOverlay> createState() => _InpaintBrushOverlayState();
}

class _InpaintBrushOverlayState extends State<InpaintBrushOverlay> {
  final List<_InpaintStroke> _strokes = [];
  List<Offset>? _activePoints;
  double _radius = 32.0;
  bool _eraseMode = false;
  bool _busy = false;

  static const double _kMinRadius = 8;
  static const double _kMaxRadius = 96;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Material(
      color: theme.colorScheme.surface,
      child: SafeArea(
        child: Column(
          children: [
            _Toolbar(
              radius: _radius,
              eraseMode: _eraseMode,
              canUndo: _strokes.isNotEmpty,
              canCommit: _strokes.isNotEmpty && !_busy,
              busy: _busy,
              onRadiusChanged: (v) => setState(() => _radius = v),
              onToggleErase: () =>
                  setState(() => _eraseMode = !_eraseMode),
              onUndo: _undo,
              onClear: _clear,
              onCancel: _busy ? null : widget.onCancel,
              onDone: _busy ? null : _commit,
            ),
            Expanded(
              child: LayoutBuilder(
                builder: (context, constraints) {
                  return Center(
                    child: AspectRatio(
                      aspectRatio:
                          widget.source.width / widget.source.height,
                      child: GestureDetector(
                        onPanStart: (d) =>
                            _beginStroke(d.localPosition),
                        onPanUpdate: (d) =>
                            _extendStroke(d.localPosition),
                        onPanEnd: (_) => _endStroke(),
                        child: CustomPaint(
                          painter: _BrushPainter(
                            source: widget.source,
                            strokes: _strokes,
                            active: _activePoints,
                            activeRadius: _radius,
                            activeErase: _eraseMode,
                          ),
                          size: Size.infinite,
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
            // Coaching strip at the bottom — explains the gesture and
            // surfaces the "model not yet available" status while the
            // LaMa scaffold is still in place.
            Container(
              color: theme.colorScheme.surfaceContainerLow,
              padding: const EdgeInsets.all(Spacing.md),
              child: Row(
                children: [
                  Icon(
                    Icons.info_outline,
                    size: 18,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                  const SizedBox(width: Spacing.xs),
                  Expanded(
                    child: Text(
                      'Paint over the area to remove. Tap Done to '
                      'inpaint it (requires the LaMa model — see '
                      'Settings → Manage AI models).',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _beginStroke(Offset pos) {
    Haptics.tap();
    _activePoints = [pos];
    setState(() {});
  }

  void _extendStroke(Offset pos) {
    if (_activePoints == null) return;
    _activePoints!.add(pos);
    setState(() {});
  }

  void _endStroke() {
    final points = _activePoints;
    if (points == null || points.isEmpty) {
      _activePoints = null;
      return;
    }
    _strokes.add(_InpaintStroke(
      points: List.unmodifiable(points),
      radius: _radius,
      erase: _eraseMode,
    ));
    _activePoints = null;
    setState(() {});
  }

  void _undo() {
    if (_strokes.isEmpty) return;
    Haptics.tap();
    setState(_strokes.removeLast);
  }

  void _clear() {
    if (_strokes.isEmpty) return;
    Haptics.impact();
    setState(_strokes.clear);
  }

  /// Bake the painted mask into a single-channel PNG at the source
  /// image's native resolution and hand it to the onDone callback.
  /// Runs at full resolution so the eventual LaMa pass operates on
  /// pixel-accurate input.
  Future<void> _commit() async {
    if (_strokes.isEmpty || _busy) return;
    setState(() => _busy = true);
    try {
      final png = await _renderMaskPng();
      _log.i('mask committed', {
        'strokes': _strokes.length,
        'bytes': png.length,
      });
      widget.onDone(InpaintBrushResult(
        maskPng: png,
        sourcePath: widget.sourcePath,
      ));
    } catch (e, st) {
      _log.e('mask render failed', error: e, stackTrace: st);
      if (!mounted) return;
      Haptics.warning();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not save mask: $e')),
      );
    } finally {
      // Always reset the flag so a flaky render doesn't strand the
      // Done button. Only the rebuild is gated on mounted.
      _busy = false;
      if (mounted) setState(() {});
    }
  }

  Future<Uint8List> _renderMaskPng() async {
    final w = widget.source.width;
    final h = widget.source.height;
    final canvasBox = (context.findRenderObject() as RenderBox?)?.size ??
        Size(w.toDouble(), h.toDouble());
    // The canvas may have a different aspect display size — but the
    // GestureDetector child is wrapped in AspectRatio matching source,
    // so points map linearly. Use the smaller of (w/canvasW, h/canvasH)
    // to compute scale; AspectRatio guarantees both ratios match.
    final scaleX = w / canvasBox.width;
    final scaleY = h / canvasBox.height;
    final scale = (scaleX + scaleY) / 2.0;

    final recorder = ui.PictureRecorder();
    final canvas = ui.Canvas(recorder)
      ..drawRect(
        Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble()),
        Paint()..color = const Color(0xFF000000),
      );
    for (final stroke in _strokes) {
      final paint = Paint()
        ..color = stroke.erase
            ? const Color(0xFF000000)
            : const Color(0xFFFFFFFF)
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round
        ..strokeWidth = stroke.radius * 2 * scale
        ..style = PaintingStyle.stroke
        ..isAntiAlias = true
        ..blendMode = stroke.erase ? BlendMode.dstOut : BlendMode.srcOver;
      if (stroke.points.length == 1) {
        final p = stroke.points.first;
        canvas.drawCircle(
          Offset(p.dx * scale, p.dy * scale),
          stroke.radius * scale,
          paint..style = PaintingStyle.fill,
        );
      } else {
        final path = Path();
        final first = stroke.points.first;
        path.moveTo(first.dx * scale, first.dy * scale);
        for (int i = 1; i < stroke.points.length; i++) {
          final p = stroke.points[i];
          path.lineTo(p.dx * scale, p.dy * scale);
        }
        canvas.drawPath(path, paint);
      }
    }
    final picture = recorder.endRecording();
    final image = await picture.toImage(w, h);
    picture.dispose();
    try {
      final byteData =
          await image.toByteData(format: ui.ImageByteFormat.png);
      if (byteData == null) {
        throw StateError('toByteData returned null');
      }
      return byteData.buffer.asUint8List();
    } finally {
      image.dispose();
    }
  }
}

class _Toolbar extends StatelessWidget {
  const _Toolbar({
    required this.radius,
    required this.eraseMode,
    required this.canUndo,
    required this.canCommit,
    required this.busy,
    required this.onRadiusChanged,
    required this.onToggleErase,
    required this.onUndo,
    required this.onClear,
    required this.onCancel,
    required this.onDone,
  });

  final double radius;
  final bool eraseMode;
  final bool canUndo;
  final bool canCommit;
  final bool busy;
  final ValueChanged<double> onRadiusChanged;
  final VoidCallback onToggleErase;
  final VoidCallback onUndo;
  final VoidCallback onClear;
  final VoidCallback? onCancel;
  final VoidCallback? onDone;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      color: theme.colorScheme.surfaceContainerHighest,
      padding: const EdgeInsets.symmetric(
        horizontal: Spacing.md,
        vertical: Spacing.sm,
      ),
      child: Column(
        children: [
          Row(
            children: [
              IconButton(
                tooltip: 'Cancel',
                icon: const Icon(Icons.close),
                onPressed: onCancel,
              ),
              const Spacer(),
              IconButton(
                tooltip: 'Undo last stroke',
                icon: const Icon(Icons.undo),
                onPressed: canUndo ? onUndo : null,
              ),
              IconButton(
                tooltip: 'Clear all strokes',
                icon: const Icon(Icons.delete_outline),
                onPressed: canUndo ? onClear : null,
              ),
              IconButton.filledTonal(
                tooltip: eraseMode
                    ? 'Eraser (tap to switch to brush)'
                    : 'Brush (tap to switch to eraser)',
                isSelected: eraseMode,
                icon: Icon(
                  eraseMode
                      ? Icons.auto_fix_off
                      : Icons.brush_outlined,
                ),
                onPressed: onToggleErase,
              ),
              const Spacer(),
              FilledButton.icon(
                icon: busy
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child:
                            CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.check),
                label: Text(busy ? 'Working…' : 'Done'),
                onPressed: canCommit ? onDone : null,
              ),
            ],
          ),
          const SizedBox(height: Spacing.xs),
          Row(
            children: [
              const Icon(Icons.radio_button_unchecked, size: 16),
              const SizedBox(width: Spacing.xs),
              Expanded(
                child: Slider(
                  min: _InpaintBrushOverlayState._kMinRadius,
                  max: _InpaintBrushOverlayState._kMaxRadius,
                  value: radius,
                  onChanged: onRadiusChanged,
                  label: '${radius.round()} px',
                ),
              ),
              SizedBox(
                width: 48,
                child: Text(
                  '${radius.round()} px',
                  textAlign: TextAlign.right,
                  style: theme.textTheme.bodySmall?.copyWith(
                    fontFeatures: const [FontFeature.tabularFigures()],
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _BrushPainter extends CustomPainter {
  _BrushPainter({
    required this.source,
    required this.strokes,
    required this.active,
    required this.activeRadius,
    required this.activeErase,
  });

  final ui.Image source;
  final List<_InpaintStroke> strokes;
  final List<Offset>? active;
  final double activeRadius;
  final bool activeErase;

  static const Color _kMaskColor = Color(0x7FFF3344);

  @override
  void paint(Canvas canvas, Size size) {
    // Underlay: source image stretched to canvas (AspectRatio in the
    // parent guarantees no distortion).
    final src = Rect.fromLTWH(
      0,
      0,
      source.width.toDouble(),
      source.height.toDouble(),
    );
    final dst = Rect.fromLTWH(0, 0, size.width, size.height);
    canvas.drawImageRect(
      source,
      src,
      dst,
      Paint()..filterQuality = FilterQuality.medium,
    );

    // Mask layer: draw white strokes into a saveLayer, then re-color
    // with the translucent red mask color via dstIn so the overlay
    // only shows where the user painted. Using saveLayer lets erase
    // strokes use BlendMode.dstOut to subtract from the layer.
    canvas.saveLayer(dst, Paint());
    for (final stroke in strokes) {
      _strokeOnto(canvas, stroke);
    }
    if (active != null && active!.isNotEmpty) {
      _strokeOnto(
        canvas,
        _InpaintStroke(
          points: active!,
          radius: activeRadius,
          erase: activeErase,
        ),
      );
    }
    // Re-color the painted alpha to the translucent red overlay.
    canvas.drawRect(
      dst,
      Paint()
        ..blendMode = BlendMode.srcIn
        ..color = _kMaskColor,
    );
    canvas.restore();
  }

  void _strokeOnto(Canvas canvas, _InpaintStroke stroke) {
    final paint = Paint()
      ..color = const Color(0xFFFFFFFF)
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..strokeWidth = stroke.radius * 2
      ..style = PaintingStyle.stroke
      ..isAntiAlias = true
      ..blendMode = stroke.erase ? BlendMode.dstOut : BlendMode.srcOver;
    if (stroke.points.length == 1) {
      final p = stroke.points.first;
      canvas.drawCircle(
        p,
        stroke.radius,
        paint..style = PaintingStyle.fill,
      );
    } else {
      final path = Path();
      path.moveTo(stroke.points.first.dx, stroke.points.first.dy);
      for (int i = 1; i < stroke.points.length; i++) {
        path.lineTo(stroke.points[i].dx, stroke.points[i].dy);
      }
      canvas.drawPath(path, paint);
    }
  }

  @override
  bool shouldRepaint(covariant _BrushPainter old) {
    if (old.source != source) return true;
    if (old.strokes.length != strokes.length) return true;
    if (old.active != active) return true;
    if (old.activeRadius != activeRadius) return true;
    if (old.activeErase != activeErase) return true;
    return false;
  }
}
