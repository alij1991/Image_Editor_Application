import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../../domain/models/scan_models.dart';

/// Full-width widget that shows a source image with four draggable
/// corner handles overlaid. The handles output [Corners] in
/// normalised 0..1 image coordinates so the backing page can feed them
/// directly to the warp pipeline.
class CornerEditor extends StatefulWidget {
  const CornerEditor({
    super.key,
    required this.imagePath,
    required this.corners,
    required this.onChanged,
  });

  final String imagePath;
  final Corners corners;
  final ValueChanged<Corners> onChanged;

  @override
  State<CornerEditor> createState() => _CornerEditorState();
}

class _CornerEditorState extends State<CornerEditor> {
  ui.Image? _loaded;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(covariant CornerEditor oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.imagePath != widget.imagePath) {
      _loaded = null;
      _load();
    }
  }

  Future<void> _load() async {
    final bytes = await File(widget.imagePath).readAsBytes();
    final codec = await ui.instantiateImageCodec(bytes);
    final frame = await codec.getNextFrame();
    if (!mounted) return;
    setState(() => _loaded = frame.image);
  }

  @override
  Widget build(BuildContext context) {
    final image = _loaded;
    if (image == null) {
      return const Center(child: CircularProgressIndicator());
    }
    final aspect = image.width / image.height;
    return LayoutBuilder(
      builder: (ctx, constraints) {
        // Fit image into the provided box preserving aspect ratio.
        var boxW = constraints.maxWidth;
        var boxH = boxW / aspect;
        if (boxH > constraints.maxHeight) {
          boxH = constraints.maxHeight;
          boxW = boxH * aspect;
        }
        final offsetX = (constraints.maxWidth - boxW) / 2;
        final offsetY = (constraints.maxHeight - boxH) / 2;
        // InteractiveViewer lets the user pinch-zoom in on a corner for
        // pixel-level adjustments. Flutter inverse-transforms pointer
        // events automatically, so our handles receive deltas in the
        // untransformed (image) coordinate space — no scaling needed.
        return InteractiveViewer(
          minScale: 1.0,
          maxScale: 6.0,
          clipBehavior: Clip.hardEdge,
          child: Stack(
            children: [
              Positioned(
                left: offsetX,
                top: offsetY,
                width: boxW,
                height: boxH,
                child: Image.file(File(widget.imagePath), fit: BoxFit.fill),
              ),
              Positioned.fill(
                child: IgnorePointer(
                  child: CustomPaint(
                    painter: _CornerOverlayPainter(
                      corners: widget.corners,
                      imageRect: Rect.fromLTWH(offsetX, offsetY, boxW, boxH),
                    ),
                  ),
                ),
              ),
              for (final handle in _handles(boxW, boxH, offsetX, offsetY))
                handle,
            ],
          ),
        );
      },
    );
  }

  List<Widget> _handles(double boxW, double boxH, double ox, double oy) {
    final current = widget.corners.list;
    const names = ['tl', 'tr', 'br', 'bl'];
    return [
      for (var i = 0; i < 4; i++)
        _Handle(
          key: ValueKey('corner_${names[i]}'),
          center: Offset(ox + current[i].x * boxW, oy + current[i].y * boxH),
          onPan: (delta) {
            final p = current[i];
            final newX = (p.x + delta.dx / boxW).clamp(0.0, 1.0);
            final newY = (p.y + delta.dy / boxH).clamp(0.0, 1.0);
            final np = Point2(newX, newY);
            final updated = switch (i) {
              0 => widget.corners.copyWith(tl: np),
              1 => widget.corners.copyWith(tr: np),
              2 => widget.corners.copyWith(br: np),
              _ => widget.corners.copyWith(bl: np),
            };
            widget.onChanged(updated);
          },
        ),
    ];
  }
}

class _Handle extends StatelessWidget {
  const _Handle({
    super.key,
    required this.center,
    required this.onPan,
  });

  final Offset center;
  final ValueChanged<Offset> onPan;

  static const double _size = 34;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Positioned(
      left: center.dx - _size / 2,
      top: center.dy - _size / 2,
      width: _size,
      height: _size,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onPanUpdate: (d) => onPan(d.delta),
        child: Container(
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: theme.colorScheme.primary.withValues(alpha: 0.9),
            border: Border.all(color: Colors.white, width: 2),
          ),
        ),
      ),
    );
  }
}

class _CornerOverlayPainter extends CustomPainter {
  _CornerOverlayPainter({required this.corners, required this.imageRect});

  final Corners corners;
  final Rect imageRect;

  @override
  void paint(Canvas canvas, Size size) {
    final pts = corners.list
        .map((p) =>
            Offset(imageRect.left + p.x * imageRect.width, imageRect.top + p.y * imageRect.height))
        .toList();
    final path = Path()..moveTo(pts[0].dx, pts[0].dy);
    for (var i = 1; i < pts.length; i++) {
      path.lineTo(pts[i].dx, pts[i].dy);
    }
    path.close();

    final fill = Paint()
      ..color = Colors.blue.withValues(alpha: 0.08)
      ..style = PaintingStyle.fill;
    canvas.drawPath(path, fill);

    final stroke = Paint()
      ..color = Colors.white
      ..strokeWidth = 2
      ..style = PaintingStyle.stroke;
    canvas.drawPath(path, stroke);

    final shadow = Paint()
      ..color = Colors.black.withValues(alpha: 0.4)
      ..strokeWidth = 4
      ..style = PaintingStyle.stroke
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 2);
    canvas.drawPath(path, shadow);
  }

  @override
  bool shouldRepaint(covariant _CornerOverlayPainter old) =>
      old.corners != corners || old.imageRect != imageRect;
}
