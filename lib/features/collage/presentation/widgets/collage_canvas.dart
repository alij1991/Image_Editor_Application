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
  });

  final CollageState state;

  /// Called when the user taps cell `i`. Null disables the tap (used
  /// during export rendering where the canvas must be inert).
  final ValueChanged<int>? onCellTap;

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
      ),
    );
  }
}

class _CollageCellWidget extends StatelessWidget {
  const _CollageCellWidget({
    required this.cell,
    required this.cornerRadius,
    required this.onTap,
  });

  final CollageCell cell;
  final double cornerRadius;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final radius = BorderRadius.circular(cornerRadius);
    final content = cell.imagePath == null
        ? _emptySlot(theme)
        : ClipRRect(
            borderRadius: radius,
            child: Image.file(
              File(cell.imagePath!),
              fit: BoxFit.cover,
              gaplessPlayback: true,
              errorBuilder: (_, __, ___) => _brokenSlot(theme),
            ),
          );
    if (onTap == null) return content;
    return Material(
      color: Colors.transparent,
      borderRadius: radius,
      clipBehavior: Clip.hardEdge,
      child: InkWell(
        onTap: onTap,
        borderRadius: radius,
        child: content,
      ),
    );
  }

  Widget _emptySlot(ThemeData theme) {
    return Container(
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(cornerRadius),
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
