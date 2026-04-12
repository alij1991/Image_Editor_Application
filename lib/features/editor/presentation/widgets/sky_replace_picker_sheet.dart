import 'package:flutter/material.dart';

import '../../../../ai/inference/sky_palette.dart';
import '../../../../ai/services/sky_replace/sky_preset.dart';
import '../../../../core/logging/app_logger.dart';
import '../../../../core/platform/haptics.dart';
import '../../../../core/theme/spacing.dart';

final _log = AppLogger('SkyReplacePickerSheet');

/// Modal sheet that lets the user pick a [SkyPreset] for Phase 9g
/// sky replacement. Pops with the selected preset, or `null` if
/// the user cancels.
///
/// Unlike the bg removal picker (which has to do a download flow),
/// every sky preset is always available — they're procedural, not
/// model-backed — so this sheet is much simpler: four cards, each
/// with a label + description + a "Use" button.
class SkyReplacePickerSheet extends StatelessWidget {
  const SkyReplacePickerSheet({super.key});

  static Future<SkyPreset?> show(BuildContext context) {
    _log.i('opened');
    return showModalBottomSheet<SkyPreset>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (_) => const SkyReplacePickerSheet(),
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
                    'Replace sky',
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
                'Pick a sky mood. Works best on landscape photos '
                'with a clear view of the sky at the top of frame.',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: Spacing.lg),
              for (final preset in SkyPreset.values)
                Padding(
                  padding: const EdgeInsets.only(bottom: Spacing.sm),
                  child: _PresetCard(
                    preset: preset,
                    onUse: () {
                      _log.i('use', {'preset': preset.name});
                      Haptics.tap();
                      Navigator.of(context).pop(preset);
                    },
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _PresetCard extends StatelessWidget {
  const _PresetCard({required this.preset, required this.onUse});

  final SkyPreset preset;
  final VoidCallback onUse;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Material(
      color: theme.colorScheme.surfaceContainerHighest,
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        onTap: onUse,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.all(Spacing.md),
          child: Row(
            children: [
              _SwatchChip(preset: preset),
              const SizedBox(width: Spacing.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      preset.label,
                      style: theme.textTheme.titleMedium,
                    ),
                    const SizedBox(height: 2),
                    Text(
                      preset.description,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              const Icon(Icons.chevron_right),
            ],
          ),
        ),
      ),
    );
  }
}

/// A tiny gradient swatch so users can see the preset without
/// running inference. The stop colors are pulled from the single
/// [SkyPalette.stopsByPreset] table so tweaking one side
/// automatically updates the other — no silent drift between the
/// picker and the actual compositor output.
class _SwatchChip extends StatelessWidget {
  const _SwatchChip({required this.preset});

  final SkyPreset preset;

  @override
  Widget build(BuildContext context) {
    final stops = SkyPalette.stopsByPreset[preset]!;
    final colors = <Color>[_toColor(stops.top)];
    final stopList = <double>[0.0];
    if (stops.middle != null) {
      colors.add(_toColor(stops.middle!));
      stopList.add(stops.midPosition);
    }
    colors.add(_toColor(stops.bottom));
    stopList.add(1.0);

    return Container(
      width: 48,
      height: 48,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(10),
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: colors,
          stops: stopList,
        ),
      ),
    );
  }

  static Color _toColor(SkyColor c) => Color.fromARGB(255, c.r, c.g, c.b);
}
