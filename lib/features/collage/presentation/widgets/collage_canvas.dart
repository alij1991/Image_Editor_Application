import 'dart:io';

import 'package:flutter/material.dart';

import '../../domain/collage_state.dart';

/// The live collage render. Lays each cell out according to its
/// normalised rect, then draws either the picked image or an empty-slot
/// placeholder inside each one. Wrap in a `RepaintBoundary` to export.
class CollageCanvas extends StatelessWidget {
  const CollageCanvas({
    super.key,
    required this.state,
    this.onCellTap,
    this.onCellTransform,
  });

  final CollageState state;

  /// Called when the user taps cell `i`. Null disables the tap (used
  /// during export rendering where the canvas must be inert).
  final ValueChanged<int>? onCellTap;

  /// VIII.2 — called when a pinch / drag gesture changes the transform
  /// for cell `i`. Null disables gesture handling (export uses this so
  /// the canvas stays inert during render).
  final void Function(int index, CellTransform transform)? onCellTransform;

  @override
  Widget build(BuildContext context) {
    return AspectRatio(
      aspectRatio: state.aspect.ratio,
      child: Container(
        color: state.backgroundColor,
        padding: EdgeInsets.all(state.outerMargin),
        child: LayoutBuilder(
          builder: (ctx, constraints) {
            final w = constraints.maxWidth;
            final h = constraints.maxHeight;
            return Stack(
              children: [
                for (var i = 0; i < state.cells.length; i++)
                  _positionedCell(w, h, i),
              ],
            );
          },
        ),
      ),
    );
  }

  Positioned _positionedCell(double w, double h, int i) {
    final cell = state.cells[i];
    final r = cell.rect;
    // Halve the inner border so adjacent cells together add up to a
    // full-width gap between them.
    final pad = state.innerBorder / 2;
    return Positioned(
      left: r.left * w + pad,
      top: r.top * h + pad,
      width: r.width * w - pad * 2,
      height: r.height * h - pad * 2,
      child: _CollageCellWidget(
        cell: cell,
        cornerRadius: state.cornerRadius,
        onTap: onCellTap == null ? null : () => onCellTap!(i),
        onTransformChanged: onCellTransform == null
            ? null
            : (t) => onCellTransform!(i, t),
      ),
    );
  }
}

class _CollageCellWidget extends StatefulWidget {
  const _CollageCellWidget({
    required this.cell,
    required this.cornerRadius,
    required this.onTap,
    required this.onTransformChanged,
  });

  final CollageCell cell;
  final double cornerRadius;
  final VoidCallback? onTap;
  final ValueChanged<CellTransform>? onTransformChanged;

  @override
  State<_CollageCellWidget> createState() => _CollageCellWidgetState();
}

class _CollageCellWidgetState extends State<_CollageCellWidget> {
  late CellTransform _gestureStart;

  @override
  void initState() {
    super.initState();
    _gestureStart = widget.cell.transform;
  }

  void _onScaleStart(ScaleStartDetails _) {
    _gestureStart = widget.cell.transform;
  }

  void _onScaleUpdate(ScaleUpdateDetails details, Size cellSize) {
    final cb = widget.onTransformChanged;
    if (cb == null) return;
    final newScale = (_gestureStart.scale * details.scale).clamp(0.5, 4.0);
    final newTx = (_gestureStart.tx +
            details.focalPointDelta.dx / cellSize.width)
        .clamp(-1.0, 1.0);
    final newTy = (_gestureStart.ty +
            details.focalPointDelta.dy / cellSize.height)
        .clamp(-1.0, 1.0);
    cb(CellTransform(scale: newScale, tx: newTx, ty: newTy));
  }

  Widget _buildContent(ThemeData theme, BorderRadius radius) {
    return widget.cell.imagePath == null
        ? _emptySlot(theme)
        : ClipRRect(
            borderRadius: radius,
            child: Transform(
              alignment: Alignment.center,
              transform: Matrix4.identity()
                ..translateByDouble(
                  widget.cell.transform.tx * 100,
                  widget.cell.transform.ty * 100,
                  0,
                  1,
                )
                ..scaleByDouble(
                  widget.cell.transform.scale,
                  widget.cell.transform.scale,
                  1,
                  1,
                ),
              child: Image.file(
                File(widget.cell.imagePath!),
                fit: BoxFit.cover,
                gaplessPlayback: true,
                errorBuilder: (_, _, _) => _brokenSlot(theme),
              ),
            ),
          );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final radius = BorderRadius.circular(widget.cornerRadius);
    return LayoutBuilder(
      builder: (ctx, constraints) {
        final size = Size(constraints.maxWidth, constraints.maxHeight);
        final content = _buildContent(theme, radius);
        if (widget.onTap == null && widget.onTransformChanged == null) {
          return content;
        }
        return Material(
          color: Colors.transparent,
          borderRadius: radius,
          clipBehavior: Clip.hardEdge,
          child: GestureDetector(
            onScaleStart:
                widget.onTransformChanged == null ? null : _onScaleStart,
            onScaleUpdate: widget.onTransformChanged == null
                ? null
                : (d) => _onScaleUpdate(d, size),
            child: InkWell(
              onTap: widget.onTap,
              borderRadius: radius,
              // Use child only — let the GestureDetector see all
              // gestures first, but keep tap routed through InkWell
              // for the ripple effect.
              child: content,
            ),
          ),
        );
      },
    );
  }

  Widget _emptySlot(ThemeData theme) {
    return Container(
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(widget.cornerRadius),
        border: Border.all(
          color: theme.colorScheme.outlineVariant,
          width: 1,
        ),
      ),
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.add_photo_alternate_outlined,
              size: 24,
              color: theme.colorScheme.onSurfaceVariant,
            ),
            const SizedBox(height: 4),
            Text(
              'Tap to add',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _brokenSlot(ThemeData theme) {
    return Container(
      color: theme.colorScheme.errorContainer,
      child: Center(
        child: Icon(
          Icons.broken_image_outlined,
          color: theme.colorScheme.onErrorContainer,
        ),
      ),
    );
  }
}
