import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../../../../ai/services/segment/mobile_sam_service.dart';
import '../../../../core/logging/app_logger.dart';
import '../../../../core/platform/haptics.dart';
import '../../../../core/theme/spacing.dart';

final _log = AppLogger('InpaintBrush');

/// Phase XVI.78c — input modes available in the overlay.
///
/// `brush` is the original paint-the-mask workflow. `smartTap` adds
/// MobileSAM-driven tap-to-segment: one tap on an object produces a
/// precise mask (~250 ms first tap to warm the encoder, ~30 ms per
/// subsequent tap on the same image). The two modes coexist — a
/// SAM-generated mask can be touched up with brush strokes, and
/// vice versa — and are union'd at commit time.
enum InpaintToolMode { brush, smartTap }

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
    this.smartTapSegmenter,
    super.key,
  });

  final ui.Image source;
  final String sourcePath;
  final ValueChanged<InpaintBrushResult> onDone;
  final VoidCallback onCancel;

  /// Phase XVI.78c — optional MobileSAM segmenter. When provided,
  /// the toolbar surfaces a Brush ↔ Tap mode toggle and the user
  /// can produce masks by tapping objects. When null, the overlay
  /// behaves exactly as before (brush-only). The widget DOES NOT
  /// own the segmenter — the caller is responsible for disposing
  /// it (typically in the same site that disposes the inpaint
  /// strategy).
  final MobileSamSegmenter? smartTapSegmenter;

  @override
  State<InpaintBrushOverlay> createState() => _InpaintBrushOverlayState();
}

class _InpaintBrushOverlayState extends State<InpaintBrushOverlay> {
  final List<_InpaintStroke> _strokes = [];
  List<Offset>? _activePoints;
  double _radius = 32.0;
  bool _eraseMode = false;
  bool _busy = false;

  /// Phase XVI.78c — current tool mode. Starts in brush mode for
  /// backwards-compat; the toolbar's mode toggle (which is only
  /// rendered when [widget.smartTapSegmenter] is non-null) flips
  /// this. Tap mode swaps the GestureDetector and surfaces the
  /// "Tap an object to segment it" coaching strip.
  InpaintToolMode _mode = InpaintToolMode.brush;

  /// Phase XVI.78c — most recent MobileSAM mask, stored at the
  /// DECODED resolution (the segmenter's working size, typically
  /// ≤ 1024 long edge). Values are 0 or 255. The painter / commit
  /// path read [_samMaskImage] instead — this byte buffer survives
  /// so any future export-the-binary-mask debug feature works
  /// without re-running SAM. Null when the user hasn't tapped yet
  /// OR cleared via [_clear].
  Uint8List? _samMask;

  /// Cached `ui.Image` view of [_samMask] for the painter. Async
  /// regeneration on mask change — `_samMaskImage` is null while
  /// the new image decodes, so the painter draws the new strokes
  /// without the SAM overlay for a frame or two. Disposed on
  /// state teardown + replaced when [_samMask] changes.
  ui.Image? _samMaskImage;

  /// Active foreground/background point prompts. Persisted so the
  /// next tap can refine the previous mask click-by-click via SAM's
  /// standard multi-point + low_res_mask refinement contract.
  final List<MobileSamPoint> _samPoints = [];

  /// Low-res logits from the previous decoder call. Fed back into
  /// the next decoder call as `mask_input` so multi-click
  /// refinement converges — without this each tap restarts from
  /// scratch, which produces a different mask shape every time.
  Float32List? _priorSamLowResLogits;

  /// True while a SAM encode/decode is in flight. Used to gate
  /// rapid double-taps and to surface a spinner in the toolbar.
  bool _samBusy = false;

  /// Phase XVI.66c.fix follow-up — used to read back the actual size
  /// of the GestureDetector (== AspectRatio child) at commit time.
  /// `_renderMaskPng` previously called `context.findRenderObject()`
  /// on the OUTER overlay, which includes the toolbar + bottom
  /// coaching strip — so the averaged stroke-to-source scale was
  /// wrong whenever the outer aspect ≠ source aspect, and the
  /// inpaint landed offset from where the user actually painted.
  final GlobalKey _strokeAreaKey = GlobalKey();

  static const double _kMinRadius = 8;
  static const double _kMaxRadius = 96;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final hasMask = _strokes.isNotEmpty || _samMask != null;
    return Material(
      color: theme.colorScheme.surface,
      child: SafeArea(
        child: Column(
          children: [
            _Toolbar(
              radius: _radius,
              eraseMode: _eraseMode,
              canUndo: _strokes.isNotEmpty || _samMask != null,
              canCommit: hasMask && !_busy && !_samBusy,
              busy: _busy || _samBusy,
              mode: _mode,
              smartTapAvailable: widget.smartTapSegmenter != null,
              onRadiusChanged: (v) => setState(() => _radius = v),
              onToggleErase: () =>
                  setState(() => _eraseMode = !_eraseMode),
              onUndo: _undo,
              onClear: _clear,
              onCancel: (_busy || _samBusy) ? null : widget.onCancel,
              onDone: (_busy || _samBusy) ? null : _commit,
              onChangeMode: widget.smartTapSegmenter == null
                  ? null
                  : _setMode,
            ),
            Expanded(
              child: LayoutBuilder(
                builder: (context, constraints) {
                  return Center(
                    child: AspectRatio(
                      aspectRatio:
                          widget.source.width / widget.source.height,
                      child: _mode == InpaintToolMode.brush
                          ? GestureDetector(
                              key: _strokeAreaKey,
                              onPanStart: (d) =>
                                  _beginStroke(d.localPosition),
                              onPanUpdate: (d) =>
                                  _extendStroke(d.localPosition),
                              onPanEnd: (_) => _endStroke(),
                              child: _buildPaintCanvas(),
                            )
                          : GestureDetector(
                              key: _strokeAreaKey,
                              onTapDown: _samBusy
                                  ? null
                                  : (d) => _smartTapAt(d.localPosition,
                                      foreground: true),
                              onLongPressStart: _samBusy
                                  ? null
                                  : (d) => _smartTapAt(d.localPosition,
                                      foreground: false),
                              child: _buildPaintCanvas(),
                            ),
                    ),
                  );
                },
              ),
            ),
            _CoachingStrip(
              mode: _mode,
              smartTapAvailable: widget.smartTapSegmenter != null,
              busy: _samBusy,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildPaintCanvas() {
    return CustomPaint(
      painter: _BrushPainter(
        source: widget.source,
        strokes: _strokes,
        active: _activePoints,
        activeRadius: _radius,
        activeErase: _eraseMode,
        samMaskImage: _samMaskImage,
      ),
      size: Size.infinite,
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
    // Undo prefers strokes over SAM (most recent action wins). When
    // only the SAM mask is present, undo drops it; when both exist,
    // undo peels strokes off until none remain, then drops the SAM
    // mask on the next press.
    if (_strokes.isNotEmpty) {
      Haptics.tap();
      setState(_strokes.removeLast);
      return;
    }
    if (_samMask != null) {
      Haptics.tap();
      setState(() {
        _samMask = null;
        _samMaskImage?.dispose();
        _samMaskImage = null;
        _samPoints.clear();
        _priorSamLowResLogits = null;
      });
    }
  }

  void _clear() {
    if (_strokes.isEmpty && _samMask == null) return;
    Haptics.impact();
    setState(() {
      _strokes.clear();
      _samMask = null;
      _samMaskImage?.dispose();
      _samMaskImage = null;
      _samPoints.clear();
      _priorSamLowResLogits = null;
    });
  }

  @override
  void dispose() {
    _samMaskImage?.dispose();
    super.dispose();
  }

  void _setMode(InpaintToolMode mode) {
    if (mode == _mode) return;
    Haptics.tap();
    setState(() => _mode = mode);
    // Warm the encoder when entering smart-tap mode so the first
    // tap doesn't pay the ~200 ms encode latency. Best-effort —
    // ignore failures (the next tap will re-attempt).
    if (mode == InpaintToolMode.smartTap) {
      final s = widget.smartTapSegmenter;
      if (s != null) {
        unawaited(_warmSegmenterCache(s));
      }
    }
  }

  Future<void> _warmSegmenterCache(MobileSamSegmenter s) async {
    try {
      _log.d('warm segmenter cache start', {'path': widget.sourcePath});
      await s.prepareImage(widget.sourcePath);
      _log.d('warm segmenter cache complete');
    } catch (e) {
      _log.w('warm segmenter cache failed (will retry on tap)',
          {'error': e.toString()});
    }
  }

  /// Phase XVI.78c — handle a tap in smart-tap mode. Maps canvas
  /// coords to decoded-source coords, asks MobileSAM for a mask,
  /// stores the result + the prior low-res mask for the next-tap
  /// refinement. Multi-tap accumulates points so the user can
  /// add a foreground tap to extend or a background tap (via
  /// long-press) to exclude.
  Future<void> _smartTapAt(Offset canvasPos,
      {required bool foreground}) async {
    final segmenter = widget.smartTapSegmenter;
    if (segmenter == null || _samBusy) return;
    final strokeAreaBox =
        _strokeAreaKey.currentContext?.findRenderObject() as RenderBox?;
    if (strokeAreaBox == null) {
      _log.w('smart tap: stroke-area RenderBox not available');
      return;
    }
    final canvasSize = strokeAreaBox.size;
    if (canvasSize.width <= 0 || canvasSize.height <= 0) {
      _log.w('smart tap: zero canvas size', {
        'w': canvasSize.width,
        'h': canvasSize.height,
      });
      return;
    }
    Haptics.tap();
    setState(() => _samBusy = true);
    try {
      // 1. Read the decoded image dims so the canvas-to-decoded
      //    coordinate mapping is correct. First call triggers the
      //    encoder (~200 ms); subsequent calls hit the cache.
      final (decW, decH) =
          await segmenter.decodedDimsFor(widget.sourcePath);
      // 2. Build the new prompt point in decoded-image coord space.
      final newPoint = MobileSamPoint.fromCanvas(
        canvasX: canvasPos.dx,
        canvasY: canvasPos.dy,
        canvasWidth: canvasSize.width,
        canvasHeight: canvasSize.height,
        decodedWidth: decW,
        decodedHeight: decH,
        foreground: foreground,
      );
      _samPoints.add(newPoint);
      _log.i('smart tap', {
        'foreground': foreground,
        'pointCount': _samPoints.length,
        'canvas': '(${canvasPos.dx.toStringAsFixed(1)}, '
            '${canvasPos.dy.toStringAsFixed(1)})',
        'decoded': '(${newPoint.x.toStringAsFixed(1)}, '
            '${newPoint.y.toStringAsFixed(1)})',
      });
      // 3. Run the decoder with every prompt collected so far +
      //    the previous call's low-res mask (= multi-click
      //    refinement contract per the SAM paper).
      final mask = await segmenter.segmentAtPoints(
        sourcePath: widget.sourcePath,
        points: _samPoints,
        priorLowResMask: _priorSamLowResLogits,
      );
      _priorSamLowResLogits = mask.lowResLogits;
      // Store mask at DECODED resolution (typically ≤ 1024 long
      // edge) — the painter draws via drawImageRect which scales
      // for free, and the commit-time PNG bake handles the
      // upscale to source res with a single drawImage call.
      final image = await _samBytesToUiImage(
        mask.alpha,
        mask.width,
        mask.height,
      );
      if (!mounted) {
        image.dispose();
        return;
      }
      setState(() {
        _samMask = mask.alpha;
        _samMaskImage?.dispose();
        _samMaskImage = image;
        _samBusy = false;
      });
    } catch (e, st) {
      _log.e('smart tap failed', error: e, stackTrace: st);
      if (!mounted) return;
      Haptics.warning();
      setState(() => _samBusy = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Smart select failed: $e')),
      );
    }
  }

  /// Build a `ui.Image` from a binary alpha buffer (0 or 255).
  /// RGBA channels all carry the alpha value, so subsequent
  /// `BlendMode.srcIn` re-color passes against the saveLayer pick
  /// up the alpha mask correctly.
  Future<ui.Image> _samBytesToUiImage(
    Uint8List alpha,
    int w,
    int h,
  ) async {
    final rgba = Uint8List(w * h * 4);
    for (var i = 0, dst = 0; i < alpha.length; i++, dst += 4) {
      final v = alpha[i];
      rgba[dst] = v;
      rgba[dst + 1] = v;
      rgba[dst + 2] = v;
      rgba[dst + 3] = v;
    }
    final completer = Completer<ui.Image>();
    ui.decodeImageFromPixels(
      rgba,
      w,
      h,
      ui.PixelFormat.rgba8888,
      completer.complete,
    );
    return completer.future;
  }

  /// Bake the painted mask into a single-channel PNG at the source
  /// image's native resolution and hand it to the onDone callback.
  /// Runs at full resolution so the eventual LaMa pass operates on
  /// pixel-accurate input.
  Future<void> _commit() async {
    final hasMask = _strokes.isNotEmpty || _samMask != null;
    if (!hasMask || _busy) return;
    setState(() => _busy = true);
    try {
      final png = await _renderMaskPng();
      _log.i('mask committed', {
        'strokes': _strokes.length,
        'samMask': _samMask != null,
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
    // Phase XVI.66c.fix follow-up — read the size of the
    // GestureDetector (which == the AspectRatio child) so the
    // stroke→source pixel mapping uses the actual touch surface.
    // Falling back to the source dimensions (1:1) is safe when the
    // key hasn't been laid out yet — `scale` then defaults to 1.0
    // and strokes land at proxy resolution unchanged.
    final strokeAreaBox =
        _strokeAreaKey.currentContext?.findRenderObject() as RenderBox?;
    final strokeAreaSize = strokeAreaBox?.size ??
        Size(w.toDouble(), h.toDouble());
    // Because the GestureDetector is wrapped in `AspectRatio(w/h)`,
    // both `w/sizeW` and `h/sizeH` are mathematically identical at
    // layout time. Use the X ratio — averaging the two (pre-fix
    // behaviour) only worked when measured against the GD itself,
    // and was outright wrong when measured against the outer overlay
    // (whose aspect includes the toolbar + bottom strip).
    final scale = w / strokeAreaSize.width;
    _log.d('mask scale computed', {
      'srcW': w,
      'srcH': h,
      'strokeAreaW': strokeAreaSize.width.toStringAsFixed(1),
      'strokeAreaH': strokeAreaSize.height.toStringAsFixed(1),
      'scale': scale.toStringAsFixed(4),
    });

    final recorder = ui.PictureRecorder();
    final canvas = ui.Canvas(recorder)
      ..drawRect(
        Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble()),
        Paint()..color = const Color(0xFF000000),
      );

    // Phase XVI.78c — if a MobileSAM mask is present, draw it as
    // the BASE layer before strokes. Strokes (in srcOver / dstOut
    // blend modes) then add to or erase from this base. Net result:
    // SAM mask ∪ paint-strokes − erase-strokes, which matches
    // intuition: SAM gives the rough shape, brush refines. We
    // reuse the painter-cached ui.Image — drawImageRect upscales
    // from the decoded resolution to source res on the GPU.
    final samImg = _samMaskImage;
    if (samImg != null) {
      canvas.drawImageRect(
        samImg,
        Rect.fromLTWH(
          0,
          0,
          samImg.width.toDouble(),
          samImg.height.toDouble(),
        ),
        Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble()),
        Paint()..filterQuality = FilterQuality.none,
      );
    }
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

/// Phase XVI.78c — bottom-of-screen coaching strip. Wording depends
/// on the current mode + whether smart-tap is even available, so
/// extracted into its own widget to keep the build method readable.
class _CoachingStrip extends StatelessWidget {
  const _CoachingStrip({
    required this.mode,
    required this.smartTapAvailable,
    required this.busy,
  });

  final InpaintToolMode mode;
  final bool smartTapAvailable;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final text = switch ((mode, smartTapAvailable, busy)) {
      (_, _, true) => 'Computing mask…',
      (InpaintToolMode.smartTap, _, _) =>
        'Tap an object to select it. Long-press to exclude an area. '
            'Switch to Brush to refine the edges.',
      (InpaintToolMode.brush, true, _) =>
        'Paint over the area to remove. Or switch to Smart Tap and tap '
            'an object to select it automatically.',
      (InpaintToolMode.brush, false, _) =>
        'Paint over the area to remove, then tap Done. Install '
            'MobileSAM in AI Models to unlock tap-to-select.',
    };
    return Container(
      color: theme.colorScheme.surfaceContainerLow,
      padding: const EdgeInsets.all(Spacing.md),
      child: Row(
        children: [
          if (busy)
            const Padding(
              padding: EdgeInsets.only(right: Spacing.xs),
              child: SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            )
          else
            Icon(
              Icons.info_outline,
              size: 18,
              color: theme.colorScheme.onSurfaceVariant,
            ),
          const SizedBox(width: Spacing.xs),
          Expanded(
            child: Text(
              text,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _Toolbar extends StatelessWidget {
  const _Toolbar({
    required this.radius,
    required this.eraseMode,
    required this.canUndo,
    required this.canCommit,
    required this.busy,
    required this.mode,
    required this.smartTapAvailable,
    required this.onRadiusChanged,
    required this.onToggleErase,
    required this.onUndo,
    required this.onClear,
    required this.onCancel,
    required this.onDone,
    required this.onChangeMode,
  });

  final double radius;
  final bool eraseMode;
  final bool canUndo;
  final bool canCommit;
  final bool busy;
  final InpaintToolMode mode;
  final bool smartTapAvailable;
  final ValueChanged<double> onRadiusChanged;
  final VoidCallback onToggleErase;
  final VoidCallback onUndo;
  final VoidCallback onClear;
  final VoidCallback? onCancel;
  final VoidCallback? onDone;
  final ValueChanged<InpaintToolMode>? onChangeMode;

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
                tooltip: mode == InpaintToolMode.smartTap
                    ? 'Undo last selection'
                    : 'Undo last stroke',
                icon: const Icon(Icons.undo),
                onPressed: canUndo ? onUndo : null,
              ),
              IconButton(
                tooltip: 'Clear all',
                icon: const Icon(Icons.delete_outline),
                onPressed: canUndo ? onClear : null,
              ),
              if (mode == InpaintToolMode.brush)
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
          if (smartTapAvailable) ...[
            const SizedBox(height: Spacing.xs),
            // Phase XVI.78c — segmented control for Brush ↔ Smart
            // Tap. Only renders when the parent passed a non-null
            // segmenter (so the brush-only flow stays unchanged on
            // devices without MobileSAM installed).
            SegmentedButton<InpaintToolMode>(
              segments: const [
                ButtonSegment(
                  value: InpaintToolMode.brush,
                  icon: Icon(Icons.brush_outlined),
                  label: Text('Brush'),
                ),
                ButtonSegment(
                  value: InpaintToolMode.smartTap,
                  icon: Icon(Icons.touch_app_outlined),
                  label: Text('Smart Tap'),
                ),
              ],
              selected: {mode},
              onSelectionChanged: onChangeMode == null || busy
                  ? null
                  : (s) => onChangeMode!(s.first),
            ),
          ],
          if (mode == InpaintToolMode.brush) ...[
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
    this.samMaskImage,
  });

  final ui.Image source;
  final List<_InpaintStroke> strokes;
  final List<Offset>? active;
  final double activeRadius;
  final bool activeErase;

  /// Phase XVI.78c — optional pre-rasterised MobileSAM mask as a
  /// ui.Image (alpha encoded in the white channel). When non-null
  /// this is drawn as the BASE alpha layer of the red overlay,
  /// then strokes add/erase on top — same composition as the
  /// commit-time PNG bake. Owned by the state; painter neither
  /// caches nor disposes it.
  final ui.Image? samMaskImage;

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

    // Phase XVI.78c — draw the SAM mask first (as the base alpha
    // layer). Strokes then add or erase on top — same composition
    // model as the commit-time PNG bake in
    // [_InpaintBrushOverlayState._renderMaskPng]. drawImageRect
    // upscales the decoded-size mask to canvas dims on the GPU,
    // single draw call regardless of mask resolution.
    final samImg = samMaskImage;
    if (samImg != null) {
      canvas.drawImageRect(
        samImg,
        Rect.fromLTWH(
          0,
          0,
          samImg.width.toDouble(),
          samImg.height.toDouble(),
        ),
        dst,
        Paint()..filterQuality = FilterQuality.none,
      );
    }

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
