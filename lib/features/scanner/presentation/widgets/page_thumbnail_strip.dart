import 'dart:io';

import 'package:flutter/material.dart';

import '../../../../core/theme/spacing.dart';
import '../../domain/models/scan_models.dart';

/// Horizontal reorderable strip of page thumbnails used on the review
/// page. Tapping a thumbnail selects it; long-press starts a reorder
/// drag.
class PageThumbnailStrip extends StatelessWidget {
  const PageThumbnailStrip({
    super.key,
    required this.pages,
    required this.selectedId,
    required this.onSelect,
    required this.onReorder,
    required this.onRemove,
  });

  final List<ScanPage> pages;
  final String selectedId;
  final ValueChanged<String> onSelect;
  final void Function(int oldIndex, int newIndex) onReorder;
  final ValueChanged<String> onRemove;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 96,
      child: ReorderableListView.builder(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: Spacing.md),
        buildDefaultDragHandles: false,
        onReorder: onReorder,
        itemCount: pages.length,
        itemBuilder: (ctx, i) {
          final page = pages[i];
          return Padding(
            key: ValueKey(page.id),
            padding: const EdgeInsets.only(right: Spacing.sm),
            child: ReorderableDragStartListener(
              index: i,
              child: _Thumb(
                page: page,
                index: i + 1,
                selected: page.id == selectedId,
                onTap: () => onSelect(page.id),
                onRemove: () => onRemove(page.id),
              ),
            ),
          );
        },
      ),
    );
  }
}

class _Thumb extends StatelessWidget {
  const _Thumb({
    required this.page,
    required this.index,
    required this.selected,
    required this.onTap,
    required this.onRemove,
  });

  final ScanPage page;
  final int index;
  final bool selected;
  final VoidCallback onTap;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final path = page.processedImagePath ?? page.rawImagePath;
    return GestureDetector(
      onTap: onTap,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Container(
            width: 72,
            height: 96,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(8),
              border: Border.all(
                width: selected ? 2.5 : 1,
                color: selected
                    ? theme.colorScheme.primary
                    : theme.colorScheme.outlineVariant,
              ),
              color: theme.colorScheme.surfaceContainer,
            ),
            clipBehavior: Clip.hardEdge,
            child: Image.file(
              File(path),
              fit: BoxFit.cover,
              gaplessPlayback: true,
              errorBuilder: (_, __, ___) =>
                  const Icon(Icons.broken_image_outlined),
            ),
          ),
          Positioned(
            left: 4,
            top: 4,
            child: Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
              decoration: BoxDecoration(
                color: Colors.black54,
                borderRadius: BorderRadius.circular(6),
              ),
              child: Text(
                '$index',
                style:
                    theme.textTheme.labelSmall?.copyWith(color: Colors.white),
              ),
            ),
          ),
          Positioned(
            right: -6,
            top: -6,
            child: Material(
              color: theme.colorScheme.surface,
              shape: const CircleBorder(),
              elevation: 1,
              child: InkWell(
                customBorder: const CircleBorder(),
                onTap: onRemove,
                child: Padding(
                  padding: const EdgeInsets.all(2),
                  child: Icon(
                    Icons.close,
                    size: 14,
                    color: theme.colorScheme.error,
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
