import 'package:flutter/material.dart';

import '../../../../core/theme/spacing.dart';
import '../../domain/models/scan_models.dart';

/// Horizontal chip row for choosing a [ScanFilter] on a single page.
class FilterChipRow extends StatelessWidget {
  const FilterChipRow({
    super.key,
    required this.selected,
    required this.onChanged,
  });

  final ScanFilter selected;
  final ValueChanged<ScanFilter> onChanged;

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.symmetric(horizontal: Spacing.md),
      child: Row(
        children: [
          for (final filter in ScanFilter.values) ...[
            ChoiceChip(
              label: Text(filter.label),
              selected: filter == selected,
              onSelected: (_) => onChanged(filter),
            ),
            const SizedBox(width: Spacing.xs),
          ],
        ],
      ),
    );
  }
}
