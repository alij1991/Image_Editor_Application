import 'package:flutter/material.dart';

import '../../../../core/logging/app_logger.dart';
import '../../../../core/theme/spacing.dart';
import '../../domain/models/scan_models.dart';

final _log = AppLogger('StrategyPicker');

/// Bottom-sheet UI letting the user choose how detection should work,
/// with the app's recommendation highlighted. Returns the chosen
/// strategy, or `null` if the user dismissed. When [nativeDisabledReason]
/// is non-null the Native tile is rendered as disabled and shows the
/// reason inline so the user knows why a perfectly visible button
/// isn't tappable.
Future<DetectorStrategy?> showStrategyPicker(
  BuildContext context, {
  required DetectorStrategy recommended,
  DetectorStrategy? current,
  String? nativeDisabledReason,
}) {
  _log.d('open', {
    'recommended': recommended.name,
    'nativeDisabled': nativeDisabledReason != null,
  });
  return showModalBottomSheet<DetectorStrategy>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (_) => _StrategyPickerSheet(
      recommended: recommended,
      current: current,
      nativeDisabledReason: nativeDisabledReason,
    ),
  );
}

class _StrategyPickerSheet extends StatelessWidget {
  const _StrategyPickerSheet({
    required this.recommended,
    required this.current,
    required this.nativeDisabledReason,
  });

  final DetectorStrategy recommended;
  final DetectorStrategy? current;
  final String? nativeDisabledReason;

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
                disabledReason: s == DetectorStrategy.native
                    ? nativeDisabledReason
                    : null,
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
    required this.disabledReason,
    required this.onTap,
  });

  final DetectorStrategy strategy;
  final bool isRecommended;
  final bool isSelected;
  final String? disabledReason;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDisabled = disabledReason != null;
    final fg = isDisabled
        ? theme.colorScheme.onSurface.withValues(alpha: 0.45)
        : null;
    return Padding(
      padding: const EdgeInsets.only(bottom: Spacing.sm),
      child: Material(
        color: isDisabled
            ? theme.colorScheme.surfaceContainer
            : isSelected
                ? theme.colorScheme.primaryContainer
                : theme.colorScheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: isDisabled ? null : onTap,
          child: Padding(
            padding: const EdgeInsets.all(Spacing.md),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(_iconFor(strategy), size: 28, color: fg),
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
                              style: theme.textTheme.titleMedium
                                  ?.copyWith(color: fg),
                            ),
                          ),
                          if (isRecommended && !isDisabled)
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
                          if (isDisabled)
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: Spacing.sm,
                                vertical: 2,
                              ),
                              decoration: BoxDecoration(
                                color: theme.colorScheme.errorContainer,
                                borderRadius: BorderRadius.circular(8),
                              ),
                              child: Text(
                                'Unavailable',
                                style: theme.textTheme.labelSmall?.copyWith(
                                  color: theme.colorScheme.onErrorContainer,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            ),
                        ],
                      ),
                      const SizedBox(height: Spacing.xs),
                      Text(
                        isDisabled ? disabledReason! : strategy.description,
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
