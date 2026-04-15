import 'package:flutter/material.dart';

import '../../../../core/logging/app_logger.dart';
import '../../../../core/theme/spacing.dart';
import '../../domain/models/scan_models.dart';

final _log = AppLogger('StrategyPicker');

/// Bottom-sheet UI letting the user choose how detection should work,
/// with the app's recommendation highlighted. Returns the chosen
/// strategy, or `null` if the user dismissed.
Future<DetectorStrategy?> showStrategyPicker(
  BuildContext context, {
  required DetectorStrategy recommended,
  DetectorStrategy? current,
}) {
  _log.d('open', {'recommended': recommended.name});
  return showModalBottomSheet<DetectorStrategy>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (_) => _StrategyPickerSheet(
      recommended: recommended,
      current: current,
    ),
  );
}

class _StrategyPickerSheet extends StatelessWidget {
  const _StrategyPickerSheet({
    required this.recommended,
    required this.current,
  });

  final DetectorStrategy recommended;
  final DetectorStrategy? current;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(
          Spacing.lg,
          0,
          Spacing.lg,
          Spacing.lg,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Detection mode', style: theme.textTheme.titleLarge),
            const SizedBox(height: Spacing.xs),
            Text(
              'How should the app find the document edges?',
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: Spacing.md),
            for (final s in DetectorStrategy.values)
              _StrategyTile(
                strategy: s,
                isRecommended: s == recommended,
                isSelected: s == current,
                onTap: () => Navigator.of(context).pop(s),
              ),
          ],
        ),
      ),
    );
  }
}

class _StrategyTile extends StatelessWidget {
  const _StrategyTile({
    required this.strategy,
    required this.isRecommended,
    required this.isSelected,
    required this.onTap,
  });

  final DetectorStrategy strategy;
  final bool isRecommended;
  final bool isSelected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: Spacing.sm),
      child: Material(
        color: isSelected
            ? theme.colorScheme.primaryContainer
            : theme.colorScheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(Spacing.md),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(_iconFor(strategy), size: 28),
                const SizedBox(width: Spacing.md),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              strategy.label,
                              style: theme.textTheme.titleMedium,
                            ),
                          ),
                          if (isRecommended)
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: Spacing.sm,
                                vertical: 2,
                              ),
                              decoration: BoxDecoration(
                                color: theme.colorScheme.primary,
                                borderRadius: BorderRadius.circular(8),
                              ),
                              child: Text(
                                'Recommended',
                                style: theme.textTheme.labelSmall?.copyWith(
                                  color: theme.colorScheme.onPrimary,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            ),
                        ],
                      ),
                      const SizedBox(height: Spacing.xs),
                      Text(
                        strategy.description,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  IconData _iconFor(DetectorStrategy s) => switch (s) {
        DetectorStrategy.native => Icons.document_scanner_outlined,
        DetectorStrategy.manual => Icons.crop_free,
        DetectorStrategy.auto => Icons.auto_awesome,
      };
}
