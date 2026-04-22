import 'dart:io';

import 'package:flutter/material.dart';

import '../../../../core/theme/spacing.dart';
import '../../domain/models/scan_models.dart';
import 'filter_preview.dart';

/// Horizontal chip row for choosing a [ScanFilter] on a single page.
///
/// VIII.4 — when [sourcePath] is provided, each chip renders a
/// thumbnail preview of the source image with that filter's
/// [FilterPreview.colorFilterFor] applied. Lets users see what each
/// filter will do without tapping. Pure label fallback when no source
/// is available (e.g. before the page lands).
class FilterChipRow extends StatelessWidget {
  const FilterChipRow({
    super.key,
    required this.selected,
    required this.onChanged,
    this.sourcePath,
  });

  final ScanFilter selected;
  final ValueChanged<ScanFilter> onChanged;

  /// Optional source image path for live filter previews. When null,
  /// chips render label-only (unchanged from pre-VIII.4 behaviour).
  final String? sourcePath;

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.symmetric(horizontal: Spacing.md),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          for (final filter in ScanFilter.values) ...[
            sourcePath == null
                ? ChoiceChip(
                    label: Text(filter.label),
                    selected: filter == selected,
                    onSelected: (_) => onChanged(filter),
                  )
                : _PreviewChip(
                    filter: filter,
                    sourcePath: sourcePath!,
                    selected: filter == selected,
                    onTap: () => onChanged(filter),
                  ),
            const SizedBox(width: Spacing.xs),
          ],
        ],
      ),
    );
  }
}

class _PreviewChip extends StatelessWidget {
  const _PreviewChip({
    required this.filter,
    required this.sourcePath,
    required this.selected,
    required this.onTap,
  });

  final ScanFilter filter;
  final String sourcePath;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final border = selected
        ? Border.all(color: theme.colorScheme.primary, width: 2)
        : Border.all(color: theme.colorScheme.outlineVariant, width: 1);
    return InkWell(
      borderRadius: BorderRadius.circular(8),
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.all(2),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(8),
          border: border,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(6),
              child: SizedBox(
                width: 36,
                height: 36,
                child: ColorFiltered(
                  colorFilter: FilterPreview.colorFilterFor(filter),
                  child: Image.file(
                    File(sourcePath),
                    fit: BoxFit.cover,
                    gaplessPlayback: true,
                    cacheWidth: 36,
                    cacheHeight: 36,
                    errorBuilder: (_, _, _) => Container(
                      color: theme.colorScheme.surfaceContainerHighest,
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 2),
            Text(
              filter.label,
              style: theme.textTheme.labelSmall?.copyWith(
                color: selected
                    ? theme.colorScheme.primary
                    : theme.colorScheme.onSurfaceVariant,
                fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
