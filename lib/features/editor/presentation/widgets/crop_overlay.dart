import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../../../../core/logging/app_logger.dart';
import '../../../../core/platform/haptics.dart';
import '../../../../core/theme/spacing.dart';
import '../../../../engine/pipeline/geometry_state.dart';

final _log = AppLogger('CropOverlay');

/// Result of a crop overlay session: the chosen rect plus the
/// aspect-ratio constraint that was active when Done was tapped.
/// `cropRect == null` means "clear any previous crop"; the rest of
/// the editor restores the full image.
class CropOverlayResult {
  CropOverlayResult({required this.cropRect, required this.aspectRatio});
  final CropRect? cropRect;
  final double? aspectRatio;
}

/// Full-screen overlay that lets the user drag a normalized crop
/// rectangle on top of the source preview.
///
/// Layout: source image fills the safe area; the crop rect is drawn
/// over it with a darkened mask outside, a thirds grid inside, and
/// 4 edge bars + 4 corner handles. Aspect-ratio chips at the top
/// constrain resizing (free / 1:1 / 4:5 / 5:4 / 3:2 / 2:3 / 16:9 /
/// 9:16). Cancel pops without changes; Done pops with the rect +
/// aspect.
///
/// Coordinates: the rect is held in normalized [0..1] of the
/// AspectRatio child so the math stays resolution-independent.
class CropOverlay extends StatefulWidget {
  const CropOverlay({
    required this.source,
    required this.initial,
    required this.initialAspect,
    required this.onDone,
    required this.onCancel,
    super.key,
  });

  final ui.Image source;
  final CropRect initial;

  /// Aspect ratio chip selected on entry (`null` = free).
  final double? initialAspect;

  final ValueChanged<CropOverlayResult> onDone;
  final VoidCallback onCancel;

  @override
  State<CropOverlay> createState() => _CropOverlayState();
}

/// Named handles. Edges resize one axis; corners resize both. The
/// inner area is the move handle.
enum _CropHandle {
  topLeft,
  topRight,
  bottomLeft,
  bottomRight,
  topEdge,
  bottomEdge,
  leftEdge,
  rightEdge,
  inside,
}

class _CropOverlayState extends State<CropOverlay> {
  late CropRect _rect;
  double? _aspect;

  static const double _kMinSize = 0.05; // 5% of source per axis
  static const double _kHandleHitRadius = 28; // px around each corner

  @override
  void initState() {
    super.initState();
    _rect = widget.initial.normalized();
    _aspect = widget.initialAspect;
    if (_aspect != null) _rect = _conformToAspect(_rect, _aspect!);
  }

  // ---- Aspect handling ----------------------------------------------

  /// Adjust [r] to match [aspect] without escaping the [0..1] box.
  /// Anchors at the rect's center so the rebalance feels natural.
  CropRect _conformToAspect(CropRect r, double aspect) {
    final cx = (r.left + r.right) / 2;
    final cy = (r.top + r.bottom) / 2;
    final srcAspect = widget.source.width / widget.source.height;
    // aspect is width/height in OUTPUT pixel coords; the rect is in
    // NORMALIZED source coords, so we need to scale by srcAspect.
    final h = r.height;
    final w = r.width;
    // Try preserving height; if that overflows widthwise, preserve
    // width instead.
    double newW = h * aspect / srcAspect;
    double newH = h;
    if (newW > 1) {
      newW = 1;
      newH = newW * srcAspect / aspect;
    }
    if (newW > w * 1.2 || newH > h * 1.2) {
      // The original rect was already smaller — keep the smaller of
      // width/height to avoid a sudden jump.
      newW = math.min(w, newW);
      newH = newW * srcAspect / aspect;
    }
    final left = (cx - newW / 2).clamp(0.0, 1.0 - newW);
    final top = (cy - newH / 2).clamp(0.0, 1.0 - newH);
    return CropRect(
      left: left,
      top: top,
      right: left + newW,
      bottom: top + newH,
    );
  }

  void _setAspect(double? aspect) {
    Haptics.tap();
    setState(() {
      _aspect = aspect;
      if (aspect != null) {
        _rect = _conformToAspect(_rect, aspect).normalized();
      }
    });
  }

  void _reset() {
    Haptics.tap();
    setState(() {
      _rect = CropRect.full;
    });
  }

  // ---- Hit-testing ---------------------------------------------------

  _CropHandle _hitHandle(Offset local, Size box) {
    final l = _rect.left * box.width;
    final t = _rect.top * box.height;
    final r = _rect.right * box.width;
    final b = _rect.bottom * box.height;
    bool nearX(double a, double b) =>
        (a - b).abs() <= _kHandleHitRadius;
    bool nearY(double a, double b) =>
        (a - b).abs() <= _kHandleHitRadius;
    final nearLeft = nearX(local.dx, l);
    final nearRight = nearX(local.dx, r);
    final nearTop = nearY(local.dy, t);
    final nearBottom = nearY(local.dy, b);
    if (nearLeft && nearTop) return _CropHandle.topLeft;
    if (nearRight && nearTop) return _CropHandle.topRight;
    if (nearLeft && nearBottom) return _CropHandle.bottomLeft;
    if (nearRight && nearBottom) return _CropHandle.bottomRight;
    if (nearTop && local.dx > l && local.dx < r) {
      return _CropHandle.topEdge;
    }
    if (nearBottom && local.dx > l && local.dx < r) {
      return _CropHandle.bottomEdge;
    }
    if (nearLeft && local.dy > t && local.dy < b) {
      return _CropHandle.leftEdge;
    }
    if (nearRight && local.dy > t && local.dy < b) {
      return _CropHandle.rightEdge;
    }
    if (local.dx >= l && local.dx <= r && local.dy >= t && local.dy <= b) {
      return _CropHandle.inside;
    }
    return _CropHandle.inside;
  }

  // ---- Drag math ----------------------------------------------------

  _CropHandle? _activeHandle;

  void _onPanStart(DragStartDetails d, Size box) {
    _activeHandle = _hitHandle(d.localPosition, box);
    Haptics.tap();
  }

  void _onPanUpdate(DragUpdateDetails d, Size box) {
    final dxNorm = d.delta.dx / box.width;
    final dyNorm = d.delta.dy / box.height;
    setState(() => _rect = _applyDrag(_rect, _activeHandle!, dxNorm, dyNorm));
  }

  CropRect _applyDrag(CropRect r, _CropHandle h, double dx, double dy) {
    double left = r.left, top = r.top, right = r.right, bottom = r.bottom;
    switch (h) {
      case _CropHandle.topLeft:
        left += dx;
        top += dy;
      case _CropHandle.topRight:
        right += dx;
        top += dy;
      case _CropHandle.bottomLeft:
        left += dx;
        bottom += dy;
      case _CropHandle.bottomRight:
        right += dx;
        bottom += dy;
      case _CropHandle.topEdge:
        top += dy;
      case _CropHandle.bottomEdge:
        bottom += dy;
      case _CropHandle.leftEdge:
        left += dx;
      case _CropHandle.rightEdge:
        right += dx;
      case _CropHandle.inside:
        // Move the whole rect, clamped so it doesn't escape the box.
        final w = right - left;
        final he = bottom - top;
        left = (left + dx).clamp(0.0, 1.0 - w);
        top = (top + dy).clamp(0.0, 1.0 - he);
        right = left + w;
        bottom = top + he;
        return CropRect(left: left, top: top, right: right, bottom: bottom);
    }
    // Clamp + min size for resize handles.
    left = left.clamp(0.0, right - _kMinSize);
    top = top.clamp(0.0, bottom - _kMinSize);
    right = right.clamp(left + _kMinSize, 1.0);
    bottom = bottom.clamp(top + _kMinSize, 1.0);
    var next = CropRect(left: left, top: top, right: right, bottom: bottom);
    if (_aspect != null) {
      // Preserve the aspect by adjusting the off-axis edge.
      next = _conformToAspect(next, _aspect!).normalized();
    }
    return next;
  }

  // ---- Build --------------------------------------------------------

  static const Map<String, double?> _kAspects = {
    'Free': null,
    '1:1': 1.0,
    '4:5': 4 / 5,
    '5:4': 5 / 4,
    '3:2': 3 / 2,
    '2:3': 2 / 3,
    '16:9': 16 / 9,
    '9:16': 9 / 16,
  };

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Material(
      color: Colors.black,
      child: SafeArea(
        child: Column(
          children: [
            _Toolbar(
              aspect: _aspect,
              onAspect: _setAspect,
              onReset: _reset,
              onCancel: widget.onCancel,
              onDone: () {
                _log.i('crop done',
                    {'rect': _rect.toString(), 'aspect': _aspect});
                Haptics.impact();
                widget.onDone(CropOverlayResult(
                  cropRect: _rect.isFull ? null : _rect,
                  aspectRatio: _aspect,
                ));
              },
            ),
            Expanded(
              child: Center(
                child: AspectRatio(
                  aspectRatio: widget.source.width / widget.source.height,
                  child: LayoutBuilder(
                    builder: (context, constraints) {
                      final box = constraints.biggest;
                      return GestureDetector(
                        onPanStart: (d) => _onPanStart(d, box),
                        onPanUpdate: (d) => _onPanUpdate(d, box),
                        onPanEnd: (_) => _activeHandle = null,
                        child: Stack(
                          fit: StackFit.expand,
                          children: [
                            RawImage(image: widget.source, fit: BoxFit.fill),
                            CustomPaint(
                              painter: _CropPainter(
                                rect: _rect,
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
          ],
        ),
      ),
    );
  }
}

class _Toolbar extends StatelessWidget {
  const _Toolbar({
    required this.aspect,
    required this.onAspect,
    required this.onReset,
    required this.onCancel,
    required this.onDone,
  });

  final double? aspect;
  final ValueChanged<double?> onAspect;
  final VoidCallback onReset;
  final VoidCallback onCancel;
  final VoidCallback onDone;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      color: theme.colorScheme.surfaceContainerHighest,
      padding: const EdgeInsets.symmetric(
        horizontal: Spacing.md,
        vertical: Spacing.xs,
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
                tooltip: 'Reset to full image',
                icon: const Icon(Icons.crop_free),
                onPressed: onReset,
              ),
              FilledButton.icon(
                icon: const Icon(Icons.check),
                label: const Text('Done'),
                onPressed: onDone,
              ),
            ],
          ),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (final entry in _CropOverlayState._kAspects.entries)
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 2),
                    child: ChoiceChip(
                      label: Text(entry.key),
                      selected: aspect == entry.value,
                      onSelected: (sel) {
                        if (sel) onAspect(entry.value);
                      },
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _CropPainter extends CustomPainter {
  _CropPainter({required this.rect, required this.color});

  final CropRect rect;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final cropRect = Rect.fromLTRB(
      rect.left * size.width,
      rect.top * size.height,
      rect.right * size.width,
      rect.bottom * size.height,
    );
    // Darken everything outside the crop rect using the even-odd fill
    // rule on a path that combines the canvas bounds and the crop rect.
    // Always paint a true-black mask regardless of theme — the
    // overlay is meant to dim the surrounding image so the cropped
    // region pops, and that effect needs the same dark wash whether
    // the chrome is light or dark.
    final path = Path()
      ..addRect(Offset.zero & size)
      ..addRect(cropRect)
      ..fillType = PathFillType.evenOdd;
    canvas.drawPath(
      path,
      Paint()..color = const Color(0xFF000000).withValues(alpha: 0.55),
    );

    // Crop border
    final border = Paint()
      ..color = color
      ..strokeWidth = 2
      ..style = PaintingStyle.stroke;
    canvas.drawRect(cropRect, border);

    // Rule-of-thirds grid. White contrasts well against the dark
    // mask outside the crop rect; theme-coloured grid lines blend
    // into typical photos and disappear visually.
    final grid = Paint()
      ..color = const Color(0xFFFFFFFF).withValues(alpha: 0.45)
      ..strokeWidth = 1;
    for (int i = 1; i < 3; i++) {
      final x = cropRect.left + cropRect.width * i / 3;
      final y = cropRect.top + cropRect.height * i / 3;
      canvas.drawLine(Offset(x, cropRect.top), Offset(x, cropRect.bottom), grid);
      canvas.drawLine(Offset(cropRect.left, y), Offset(cropRect.right, y), grid);
    }

    // Corner handles — chunky white L-brackets so the user sees them
    // even when the underlying image is white.
    const handleLength = 18.0;
    const handleStroke = 4.0;
    final handlePaint = Paint()
      ..color = color
      ..strokeWidth = handleStroke
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;
    void drawCorner(Offset c, double dx, double dy) {
      canvas.drawLine(c, c + Offset(handleLength * dx, 0), handlePaint);
      canvas.drawLine(c, c + Offset(0, handleLength * dy), handlePaint);
    }

    drawCorner(cropRect.topLeft, 1, 1);
    drawCorner(cropRect.topRight, -1, 1);
    drawCorner(cropRect.bottomLeft, 1, -1);
    drawCorner(cropRect.bottomRight, -1, -1);
  }

  @override
  bool shouldRepaint(covariant _CropPainter old) =>
      old.rect != rect || old.color != color;
}
