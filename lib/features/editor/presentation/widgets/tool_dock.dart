import 'package:flutter/material.dart';

import '../../../../core/logging/app_logger.dart';
import '../../../../core/platform/haptics.dart';
import '../../../../core/theme/spacing.dart';
import '../../../../engine/pipeline/op_spec.dart';

final _log = AppLogger('ToolDock');

/// Bottom tool dock. Renders category chips (with edit-indicator dots)
/// and a child panel below. Stateless — the caller owns the active
/// category so gesture layers and canvas siblings can read the same
/// value without props drilling through the dock.
class ToolDock extends StatelessWidget {
  const ToolDock({
    required this.active,
    required this.activeCategories,
    required this.onCategoryChanged,
    required this.child,
    super.key,
  });

  final OpCategory active;

  /// Set of categories that currently contain enabled edits — used to
  /// paint a small dot on the chip.
  final Set<OpCategory> activeCategories;

  final ValueChanged<OpCategory> onCategoryChanged;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Material(
      color: theme.colorScheme.surface,
      elevation: 8,
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _CategoryTabs(
              active: active,
              activeCategories: activeCategories,
              onSelect: (cat) {
                _log.d('category selected', {'category': cat.label});
                Haptics.tap();
                onCategoryChanged(cat);
              },
            ),
            const Divider(height: 1),
            Flexible(
              child: SingleChildScrollView(
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: Spacing.sm),
                  child: child,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _CategoryTabs extends StatelessWidget {
  const _CategoryTabs({
    required this.active,
    required this.activeCategories,
    required this.onSelect,
  });

  final OpCategory active;
  final Set<OpCategory> activeCategories;
  final ValueChanged<OpCategory> onSelect;

  static const Map<OpCategory, String> _tooltips = {
    OpCategory.light: 'Exposure, contrast, highlights, shadows, levels',
    OpCategory.color: 'Temperature, tint, saturation, HSL, split toning',
    OpCategory.effects: 'Vignette, grain, blurs, stylized filters',
    OpCategory.detail: 'Sharpen, noise reduction',
    OpCategory.optics: 'Lens corrections (coming soon)',
    OpCategory.geometry: 'Crop, rotate, perspective (coming soon)',
  };

  static const Map<OpCategory, IconData> _icons = {
    OpCategory.light: Icons.wb_sunny_outlined,
    OpCategory.color: Icons.palette_outlined,
    OpCategory.effects: Icons.auto_awesome_outlined,
    OpCategory.detail: Icons.texture_outlined,
    OpCategory.optics: Icons.camera_outlined,
    OpCategory.geometry: Icons.crop_outlined,
  };

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    const categories = OpCategory.values;
    return SizedBox(
      height: 52,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(
          horizontal: Spacing.md,
          vertical: Spacing.sm,
        ),
        itemCount: categories.length,
        separatorBuilder: (_, _) => const SizedBox(width: Spacing.sm),
        itemBuilder: (context, index) {
          final cat = categories[index];
          final selected = cat == active;
          final hasEdits = activeCategories.contains(cat);
          return Tooltip(
            message: _tooltips[cat] ?? cat.label,
            waitDuration: const Duration(milliseconds: 400),
            child: Badge(
              backgroundColor: hasEdits
                  ? theme.colorScheme.tertiary
                  : Colors.transparent,
              isLabelVisible: hasEdits,
              alignment: AlignmentDirectional.topEnd,
              smallSize: 7,
              child: ChoiceChip(
                label: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(_icons[cat], size: 16),
                    const SizedBox(width: Spacing.xs),
                    Text(cat.label),
                  ],
                ),
                selected: selected,
                onSelected: (_) => onSelect(cat),
                labelStyle: TextStyle(
                  color: selected
                      ? theme.colorScheme.onPrimary
                      : theme.colorScheme.onSurfaceVariant,
                  fontWeight: FontWeight.w500,
                ),
                selectedColor: theme.colorScheme.primary,
              ),
            ),
          );
        },
      ),
    );
  }
}
