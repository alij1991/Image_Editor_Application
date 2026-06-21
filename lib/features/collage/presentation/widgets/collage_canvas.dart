import 'dart:io';

import 'package:flutter/material.dart';

import '../../domain/collage_state.dart';

/// D3 (XVI.123) — the decode `cacheWidth` for one collage cell, sized to
/// the EXPORT ceiling rather than the screen. The export rasterises this
/// same widget tree at up to `maxOutputLongEdge / canvasLongEdge`×
/// (see [effectiveCollagePixelRatio]), so a cell's exported pixels are
/// `cellLongEdge × that ratio`. Decoding at exactly that size keeps the
/// export sharp (a screen-sized decode would upscale and blur it) while
/// bounding memory to ≈ one export buffer for normal-aspect sources —
/// instead of the ~700 MB you'd get holding every 20 MP source at full
/// resolution. (`cacheWidth` caps width only, so an extreme-aspect source
/// can exceed that estimate, but it's still a large reduction and Flutter
/// never upscales, so the decode is never larger than the source.)
///
/// Note: the decode deliberately ignores live pinch-zoom
/// (`CellTransform.scale`, up to 4×) — folding it in would force a
/// re-decode on every gesture frame, so a strongly zoomed-in cell may
/// look slightly soft. Returns null for a degenerate cell so `Image.file`
/// falls back to a full decode rather than a 0-px one.
int? collageCellCacheWidth({
  required double cellLongEdge,
  required double canvasLongEdge,
  required int maxOutputLongEdge,
}) {
  if (!cellLongEdge.isFinite ||
      cellLongEdge <= 0 ||
      !canvasLongEdge.isFinite ||
      canvasLongEdge <= 0 ||
      maxOutputLongEdge <= 0) {
    return null;
  }
  final exportRatio = maxOutputLongEdge / canvasLongEdge;
  return (cellLongEdge * exportRatio).ceil();
}

/// The live collage render. Lays each cell out according to its
/// normalised rect, then draws either the picked image or an empty-slot
/// placeholder inside each one. Wrap in a `RepaintBoundary` to export.
class CollageCanvas extends StatelessWidget {
  const CollageCanvas({
    super.key,
    required this.state,
    this.onCellTap,
    this.onCellTransform,
    this.maxOutputLongEdge = 4096,
  });

  final CollageState state;

  /// D3 (XVI.123) — the export long-edge ceiling (px). Used to size each
  /// cell's decode `cacheWidth` so the export (which rasterises this same
  /// tree) stays sharp while bounding decode memory. The page passes the
  /// device-tier value, matching the exporter's cap; the default keeps
  /// display-only / test usages safe. Keep in sync with the value passed
  /// to `CollageExporter.export(maxOutputLongEdge:)`.
  final int maxOutputLongEdge;

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
            final canvasLongEdge = w > h ? w : h;
            return Stack(
              children: [
                for (var i = 0; i < state.cells.length; i++)
                  _positionedCell(w, h, canvasLongEdge, i),
              ],
            );
          },
        ),
      ),
    );
  }

  Positioned _positionedCell(double w, double h, double canvasLongEdge, int i) {
    final cell = state.cells[i];
    final r = cell.rect;
    // Halve the inner border so adjacent cells together add up to a
    // full-width gap between them.
    final pad = state.innerBorder / 2;
    final cellW = r.width * w - pad * 2;
    final cellH = r.height * h - pad * 2;
    return Positioned(
      left: r.left * w + pad,
      top: r.top * h + pad,
      width: cellW,
      height: cellH,
      child: _CollageCellWidget(
        cell: cell,
        cornerRadius: state.cornerRadius,
        decodeCacheWidth: collageCellCacheWidth(
          cellLongEdge: cellW > cellH ? cellW : cellH,
          canvasLongEdge: canvasLongEdge,
          maxOutputLongEdge: maxOutputLongEdge,
        ),
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
    required this.decodeCacheWidth,
    required this.onTap,
    required this.onTransformChanged,
  });

  final CollageCell cell;
  final double cornerRadius;

  /// D3 (XVI.123) — decode `cacheWidth` for this cell's image, sized to
  /// the export ceiling by [collageCellCacheWidth]. Null → full decode.
  final int? decodeCacheWidth;
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
                // D3 (XVI.123) — decode sized to the export ceiling (see
                // collageCellCacheWidth): sharp export, bounded memory
                // instead of full-res (a 3×3 grid of 20 MP sources is
                // ~700 MB decoded).
                cacheWidth: widget.decodeCacheWidth,
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
