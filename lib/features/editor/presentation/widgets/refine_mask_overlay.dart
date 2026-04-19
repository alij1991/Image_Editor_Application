import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../../../../core/logging/app_logger.dart';
import '../../../../core/platform/haptics.dart';
import '../../../../core/theme/spacing.dart';

final _log = AppLogger('RefineMask');

/// Result handed back when the user commits a refined cutout. The
/// new image replaces whatever the AI service originally produced;
/// callers store it in the session's cutout cache via
/// `EditorSession.replaceCutoutImage`.
class RefineMaskResult {
  RefineMaskResult({required this.layerId, required this.image});
  final String layerId;
  final ui.Image image;
}

/// One brush stroke captured during the refine session. Stored in
/// canvas-local pixels so the painter can replay them at any zoom
/// without resampling.
class _RefineStroke {
  _RefineStroke({
    required this.points,
    required this.radius,
    required this.erase,
  });
  final List<Offset> points;
  final double radius;
  final bool erase;
}

/// Paint-to-refine overlay for AdjustmentLayer cutouts (BG removal,
/// sky replace, beautify). The user sees the AI's existing cutout on
/// a checkerboard backdrop and brushes to restore (add alpha) or
/// erase (remove alpha) parts of it.
///
/// Mental model: the AI service got most of the mask right; this is
/// the user's chance to clean up the seams.
///
///   - **Restore brush** — paints the SOURCE photo back into the mask.
///     Useful when the AI cut away too much (an arm vanished, a
///     subject's hair has holes).
///   - **Erase brush** — punches holes in the mask. Useful when the
///     AI kept too much (a stray piece of background, a hand the
///     user wants gone).
///   - **Brush size slider** for fine vs coarse work.
///   - **Undo** / **Clear** mid-session.
///   - **Done** bakes the strokes into a fresh ui.Image at the
///     cutout's native resolution and hands it to onDone.
class RefineMaskOverlay extends StatefulWidget {
  const RefineMaskOverlay({
    required this.layerId,
    required this.source,
    required this.cutout,
    required this.onDone,
    required this.onCancel,
    super.key,
  });

  /// Id of the AdjustmentLayer being refined.
  final String layerId;

  /// The original full-frame source photo. Used for the restore
  /// brush — when the user paints to add, we sample these pixels
  /// back into the cutout.
  final ui.Image source;

  /// The AI-generated cutout we're starting from. Has alpha where
  /// the AI selected the subject, transparent everywhere else.
  final ui.Image cutout;

  final ValueChanged<RefineMaskResult> onDone;
  final VoidCallback onCancel;

  @override
  State<RefineMaskOverlay> createState() => _RefineMaskOverlayState();
}

class _RefineMaskOverlayState extends State<RefineMaskOverlay> {
  final List<_RefineStroke> _strokes = [];
  List<Offset>? _activePoints;
  double _radius = 32.0;
  bool _eraseMode = false;
  bool _busy = false;
  Size _canvasSize = Size.zero;

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
                        onPanStart: (d) => _beginStroke(d.localPosition),
                        onPanUpdate: (d) => _extendStroke(d.localPosition),
                        onPanEnd: (_) => _endStroke(),
                        child: LayoutBuilder(
                          builder: (context, inner) {
                            _canvasSize = inner.biggest;
                            return CustomPaint(
                              painter: _RefinePainter(
                                source: widget.source,
                                cutout: widget.cutout,
                                strokes: _strokes,
                                active: _activePoints,
                                activeRadius: _radius,
                                activeErase: _eraseMode,
                              ),
                              size: Size.infinite,
                            );
                          },
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
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
                      _eraseMode
                          ? 'Erase mode — brush to remove parts of the '
                              'AI selection.'
                          : 'Restore mode — brush to bring back parts '
                              'the AI cut away.',
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
    _strokes.add(_RefineStroke(
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

  /// Bake the strokes onto the existing cutout at its native
  /// resolution and hand the result to onDone. Restore strokes
  /// composite source pixels INTO the cutout via dstATop; erase
  /// strokes punch holes via dstOut.
  Future<void> _commit() async {
    if (_strokes.isEmpty || _busy) return;
    setState(() => _busy = true);
    try {
      final image = await _renderRefinedCutout();
      _log.i('refine committed', {
        'strokes': _strokes.length,
        'w': image.width,
        'h': image.height,
      });
      widget.onDone(
        RefineMaskResult(layerId: widget.layerId, image: image),
      );
    } catch (e, st) {
      _log.e('refine render failed', error: e, stackTrace: st);
      if (!mounted) return;
      Haptics.warning();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not refine mask: $e')),
      );
    } finally {
      _busy = false;
      if (mounted) setState(() {});
    }
  }

  Future<ui.Image> _renderRefinedCutout() async {
    final w = widget.source.width;
    final h = widget.source.height;
    if (_canvasSize.width <= 0 || _canvasSize.height <= 0) {
      throw StateError('Canvas size unknown — paint at least once first');
    }
    final scale = w / _canvasSize.width;

    final recorder = ui.PictureRecorder();
    final canvas = ui.Canvas(recorder);

    // Layer 1: the existing cutout (alpha intact).
    canvas.drawImageRect(
      widget.cutout,
      Rect.fromLTWH(
          0, 0, widget.cutout.width.toDouble(), widget.cutout.height.toDouble()),
      Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble()),
      Paint()..filterQuality = FilterQuality.medium,
    );

    // Layer 2: restore strokes — composite source pixels into the
    // mask using a saveLayer and the source-image as the texture.
    final restoreStrokes =
        _strokes.where((s) => !s.erase).toList(growable: false);
    if (restoreStrokes.isNotEmpty) {
      // Mask out the source: paint white strokes into a saveLayer,
      // then srcIn the source image so only the painted areas survive.
      canvas.saveLayer(
        Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble()),
        Paint(),
      );
      for (final stroke in restoreStrokes) {
        _strokeOnto(canvas, stroke, scale, const Color(0xFFFFFFFF),
            BlendMode.srcOver);
      }
      canvas.drawImageRect(
        widget.source,
        Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble()),
        Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble()),
        Paint()..blendMode = BlendMode.srcIn,
      );
      canvas.restore();
    }

    // Layer 3: erase strokes — punch holes via dstOut.
    final eraseStrokes =
        _strokes.where((s) => s.erase).toList(growable: false);
    for (final stroke in eraseStrokes) {
      _strokeOnto(canvas, stroke, scale,
          const Color(0xFFFFFFFF), BlendMode.dstOut);
    }

    final picture = recorder.endRecording();
    try {
      return await picture.toImage(w, h);
    } finally {
      picture.dispose();
    }
  }

  void _strokeOnto(
    ui.Canvas canvas,
    _RefineStroke stroke,
    double scale,
    Color color,
    BlendMode blend,
  ) {
    final paint = Paint()
      ..color = color
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..strokeWidth = stroke.radius * 2 * scale
      ..style = PaintingStyle.stroke
      ..isAntiAlias = true
      ..blendMode = blend;
    if (stroke.points.length == 1) {
      final p = stroke.points.first;
      canvas.drawCircle(
        Offset(p.dx * scale, p.dy * scale),
        stroke.radius * scale,
        paint..style = PaintingStyle.fill,
      );
    } else {
      final path = Path();
      path.moveTo(
        stroke.points.first.dx * scale,
        stroke.points.first.dy * scale,
      );
      for (int i = 1; i < stroke.points.length; i++) {
        path.lineTo(
          stroke.points[i].dx * scale,
          stroke.points[i].dy * scale,
        );
      }
      canvas.drawPath(path, paint);
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
                    ? 'Erase (tap to switch to restore)'
                    : 'Restore (tap to switch to erase)',
                isSelected: eraseMode,
                icon: Icon(
                  eraseMode ? Icons.auto_fix_off : Icons.brush_outlined,
                ),
                onPressed: onToggleErase,
              ),
              const Spacer(),
              FilledButton.icon(
                icon: busy
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
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
                  min: _RefineMaskOverlayState._kMinRadius,
                  max: _RefineMaskOverlayState._kMaxRadius,
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

class _RefinePainter extends CustomPainter {
  _RefinePainter({
    required this.source,
    required this.cutout,
    required this.strokes,
    required this.active,
    required this.activeRadius,
    required this.activeErase,
  });

  final ui.Image source;
  final ui.Image cutout;
  final List<_RefineStroke> strokes;
  final List<Offset>? active;
  final double activeRadius;
  final bool activeErase;

  static const Color _kCheckerLight = Color(0xFF3A3A3A);
  static const Color _kCheckerDark = Color(0xFF2A2A2A);

  @override
  void paint(Canvas canvas, Size size) {
    // Checkerboard background — makes the cutout's transparent
    // regions obviously transparent.
    _paintCheckerboard(canvas, size);

    // Composite into a layer so erase strokes can dstOut against
    // the cutout, and restore strokes can srcATop the source.
    final dst = Offset.zero & size;
    canvas.saveLayer(dst, Paint());
    canvas.drawImageRect(
      cutout,
      Rect.fromLTWH(0, 0, cutout.width.toDouble(), cutout.height.toDouble()),
      dst,
      Paint()..filterQuality = FilterQuality.medium,
    );

    // Restore strokes preview: composite a saveLayer of stroke
    // shapes, then srcIn the source image.
    final restoreStrokes =
        strokes.where((s) => !s.erase).toList(growable: false);
    final activeIsRestore =
        active != null && active!.isNotEmpty && !activeErase;
    if (restoreStrokes.isNotEmpty || activeIsRestore) {
      canvas.saveLayer(dst, Paint());
      for (final stroke in restoreStrokes) {
        _drawStroke(canvas, stroke);
      }
      if (activeIsRestore) {
        _drawStroke(
          canvas,
          _RefineStroke(
            points: active!,
            radius: activeRadius,
            erase: false,
          ),
        );
      }
      // Source image masked to the painted strokes only.
      canvas.drawImageRect(
        source,
        Rect.fromLTWH(0, 0, source.width.toDouble(), source.height.toDouble()),
        dst,
        Paint()..blendMode = BlendMode.srcIn,
      );
      canvas.restore();
    }

    // Erase strokes preview: dstOut against the layer (which holds
    // the cutout + any restored regions).
    for (final stroke in strokes.where((s) => s.erase)) {
      _drawStroke(canvas, stroke, blend: BlendMode.dstOut);
    }
    if (active != null && active!.isNotEmpty && activeErase) {
      _drawStroke(
        canvas,
        _RefineStroke(
          points: active!,
          radius: activeRadius,
          erase: true,
        ),
        blend: BlendMode.dstOut,
      );
    }

    canvas.restore();

    // Live brush ring at the active stroke's last point so the user
    // sees how big the brush is right now.
    if (active != null && active!.isNotEmpty) {
      final p = active!.last;
      final ring = Paint()
        ..color = const Color(0xFFFFFFFF)
        ..strokeWidth = 1.5
        ..style = PaintingStyle.stroke;
      canvas.drawCircle(p, activeRadius, ring);
    }
  }

  void _drawStroke(
    Canvas canvas,
    _RefineStroke stroke, {
    BlendMode blend = BlendMode.srcOver,
  }) {
    final paint = Paint()
      ..color = const Color(0xFFFFFFFF)
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..strokeWidth = stroke.radius * 2
      ..style = PaintingStyle.stroke
      ..isAntiAlias = true
      ..blendMode = blend;
    if (stroke.points.length == 1) {
      canvas.drawCircle(
        stroke.points.first,
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

  void _paintCheckerboard(Canvas canvas, Size size) {
    const cell = 12.0;
    final light = Paint()..color = _kCheckerLight;
    final dark = Paint()..color = _kCheckerDark;
    canvas.drawRect(Offset.zero & size, dark);
    for (double y = 0; y < size.height; y += cell) {
      for (double x = 0; x < size.width; x += cell) {
        final even = (((x ~/ cell) + (y ~/ cell)) % 2) == 0;
        if (even) {
          canvas.drawRect(
            Rect.fromLTWH(x, y, cell, cell),
            light,
          );
        }
      }
    }
  }

  @override
  bool shouldRepaint(covariant _RefinePainter old) {
    if (old.source != source) return true;
    if (old.cutout != cutout) return true;
    if (old.strokes.length != strokes.length) return true;
    if (old.active != active) return true;
    if (old.activeRadius != activeRadius) return true;
    if (old.activeErase != activeErase) return true;
    return false;
  }
}
