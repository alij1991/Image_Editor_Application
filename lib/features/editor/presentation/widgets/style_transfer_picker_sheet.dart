import 'package:flutter/material.dart';

import '../../../../ai/services/style_transfer/style_transfer_service.dart';
import '../../../../core/logging/app_logger.dart';
import '../../../../core/platform/haptics.dart';
import '../../../../core/theme/spacing.dart';

final _log = AppLogger('StyleTransferPickerSheet');

/// Modal sheet for picking a [StylePreset] to apply with the Magenta
/// style-transfer model. Pops with the chosen preset or `null` on
/// cancel.
///
/// Until the bundled model lands, the sheet still opens and the
/// user can pick a style — the actual stylize call surfaces a
/// "model not yet available" snackbar from [StyleTransferService].
/// Keeping the picker live now means the UI doesn't change shape on
/// the day the model file ships.
class StyleTransferPickerSheet extends StatelessWidget {
  const StyleTransferPickerSheet({super.key});

  static Future<StylePreset?> show(BuildContext context) {
    _log.i('opened');
    return showModalBottomSheet<StylePreset>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (_) => const StyleTransferPickerSheet(),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(Spacing.lg),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Text(
                    'Style transfer',
                    style: theme.textTheme.titleLarge,
                  ),
                  const Spacer(),
                  IconButton(
                    tooltip: 'Close',
                    icon: const Icon(Icons.close),
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                ],
              ),
              const SizedBox(height: Spacing.xs),
              Text(
                'Stylise your photo with one of the bundled looks. '
                'Heavier than a filter — runs the Magenta arbitrary-'
                'style transfer model on-device.',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: Spacing.md),
              Container(
                padding: const EdgeInsets.all(Spacing.sm),
                decoration: BoxDecoration(
                  color: theme.colorScheme.tertiaryContainer
                      .withValues(alpha: 0.5),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Row(
                  children: [
                    Icon(Icons.info_outline,
                        size: 18,
                        color: theme.colorScheme.onTertiaryContainer),
                    const SizedBox(width: Spacing.xs),
                    Expanded(
                      child: Text(
                        'Preview build — the model file lands in a '
                        'follow-up update. Picking a style now will '
                        'show a coaching message instead of running.',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onTertiaryContainer,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: Spacing.lg),
              GridView.count(
                crossAxisCount: 3,
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                crossAxisSpacing: Spacing.sm,
                mainAxisSpacing: Spacing.sm,
                children: [
                  for (final preset in StylePreset.values)
                    _StyleTile(
                      preset: preset,
                      onTap: () {
                        _log.i('pick', {'preset': preset.name});
                        Haptics.tap();
                        Navigator.of(context).pop(preset);
                      },
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _StyleTile extends StatelessWidget {
  const _StyleTile({required this.preset, required this.onTap});

  final StylePreset preset;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Material(
      color: theme.colorScheme.surfaceContainerHighest,
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(Spacing.sm),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text(preset.emoji, style: const TextStyle(fontSize: 32)),
              const SizedBox(height: Spacing.xs),
              Text(
                preset.label,
                style: theme.textTheme.bodySmall,
                textAlign: TextAlign.center,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
