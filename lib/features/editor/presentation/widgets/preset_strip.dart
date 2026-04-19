import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../../../../core/feedback/user_feedback.dart';
import '../../../../core/logging/app_logger.dart';
import '../../../../core/platform/haptics.dart';
import '../../../../core/theme/spacing.dart';
import '../../../../engine/presets/built_in_presets.dart';
import '../../../../engine/presets/preset.dart';
import '../../../../engine/presets/preset_metadata.dart';
import '../../../../engine/presets/preset_repository.dart';
import '../../domain/preset_thumbnail_cache.dart';
import '../notifiers/editor_session.dart';

final _log = AppLogger('PresetStrip');

/// Horizontal scrollable strip of preset tiles under a "Presets" header.
///
/// Interaction:
///   - Tap a preset → [EditorSession.applyPreset] applies at the
///     preset's default amount (100% for subtle / standard presets,
///     80% for strong presets so users have headroom to dial up).
///   - Tap the **currently-applied** tile a second time → opens a
///     bottom sheet with an Amount slider (0–150%).
///   - Long-press a custom preset → offers delete.
///
/// The trailing "Save" tile captures the current pipeline as a named
/// custom preset.
///
/// Tiles render live previews of the source photo through each
/// preset's matrix-composable ops via [PresetThumbnailCache]. Effects
/// that can't be folded into a matrix (clarity, grain, vignette overlay
/// aside, etc.) are skipped at thumbnail scale — the approximation
/// captures the dominant colour character of each preset which is what
/// users actually scan the strip for.
class PresetStrip extends StatefulWidget {
  const PresetStrip({required this.session, super.key});

  final EditorSession session;

  @override
  State<PresetStrip> createState() => _PresetStripState();
}

class _PresetStripState extends State<PresetStrip> {
  final PresetRepository _repo = PresetRepository();
  List<Preset> _presets = const [];
  bool _loading = true;

  /// Selected category pill. `null` = "All".
  String? _selectedCategory;

  /// Presets filtered by [_selectedCategory]. Custom (non-built-in)
  /// presets always appear when "All" is selected and are hidden when
  /// a category pill is active (custom presets have user-supplied
  /// category strings that rarely match the canonical set).
  List<Preset> get _visiblePresets {
    final cat = _selectedCategory;
    if (cat == null) return _presets;
    return _presets.where((p) => p.category == cat).toList(growable: false);
  }

  @override
  void initState() {
    super.initState();
    _reload();
  }

  Future<void> _reload() async {
    try {
      final presets = await _repo.loadAll();
      if (!mounted) return;
      setState(() {
        _presets = presets;
        _loading = false;
      });
      _log.i('loaded', {'count': presets.length});
    } catch (e, st) {
      _log.e('reload failed', error: e, stackTrace: st);
      if (!mounted) return;
      setState(() => _loading = false);
    }
  }

  @override
  void dispose() {
    _repo.close();
    super.dispose();
  }

  Future<void> _onSaveCurrent() async {
    final name = await showDialog<String>(
      context: context,
      builder: (_) => const _SavePresetDialog(),
    );
    if (name == null || name.trim().isEmpty) return;
    try {
      await _repo.saveFromPipeline(
        name: name.trim(),
        pipeline: widget.session.committedPipeline,
      );
      await _reload();
      if (!mounted) return;
      Haptics.impact();
      UserFeedback.success(context, 'Preset "${name.trim()}" saved');
    } catch (e, st) {
      _log.e('save failed', error: e, stackTrace: st);
      if (!mounted) return;
      Haptics.warning();
      UserFeedback.error(context, 'Could not save preset: $e');
    }
  }

  Future<void> _onDelete(Preset preset) async {
    if (preset.builtIn) {
      Haptics.warning();
      if (mounted) {
        UserFeedback.error(context, 'Built-in presets cannot be deleted');
      }
      return;
    }
    // Long-press deletion is easy to fat-finger — confirm before
    // dropping a custom preset. Only one tap on the dialog's Delete
    // button actually commits.
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete preset?'),
        content: Text('“${preset.name}” will be removed permanently.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton.tonal(
            style: FilledButton.styleFrom(
              foregroundColor: Theme.of(ctx).colorScheme.error,
            ),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true) {
      _log.d('delete cancelled', {'id': preset.id});
      return;
    }
    try {
      await _repo.delete(preset.id);
      await _reload();
      if (!mounted) return;
      Haptics.impact();
      UserFeedback.info(context, 'Preset "${preset.name}" deleted');
    } catch (e, st) {
      _log.e('delete failed', error: e, stackTrace: st);
      if (!mounted) return;
      UserFeedback.error(context, 'Could not delete preset: $e');
    }
  }

  void _onTileTap(Preset preset) {
    final active = widget.session.appliedPreset.value;
    final isAlreadyActive = active?.preset.id == preset.id;
    if (isAlreadyActive && preset.id != 'builtin.none') {
      // Second tap — open the Amount sheet so the user can dial
      // intensity without reaching for any other control.
      _openAmountSheet(preset, active!.amount);
      return;
    }
    _log.i('apply tapped', {'id': preset.id, 'name': preset.name});
    Haptics.tap();
    widget.session.applyPreset(preset);
    UserFeedback.info(
      context,
      preset.id == 'builtin.none'
          ? 'Reset to original'
          : 'Applied "${preset.name}"',
    );
  }

  Future<void> _openAmountSheet(Preset preset, double initial) async {
    Haptics.tap();
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => _PresetAmountSheet(
        preset: preset,
        initial: initial,
        onChanged: (value) => widget.session.setPresetAmount(value),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(
            Spacing.lg,
            Spacing.sm,
            Spacing.lg,
            0,
          ),
          child: Row(
            children: [
              Text(
                'PRESETS',
                style: theme.textTheme.labelSmall?.copyWith(
                  color: theme.colorScheme.primary,
                  letterSpacing: 1.2,
                ),
              ),
              const SizedBox(width: Spacing.xs),
              Tooltip(
                message:
                    'Tap to apply. Tap the active preset again to adjust its strength. Long-press a custom preset to delete it.',
                child: Icon(
                  Icons.help_outline,
                  size: 14,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
        if (_loading)
          const SizedBox(
            height: 96,
            child: Center(
              child: SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            ),
          )
        else ...[
          _CategoryRail(
            selected: _selectedCategory,
            onChanged: (c) {
              Haptics.tap();
              setState(() => _selectedCategory = c);
              _log.d('category', {'selected': c ?? 'all'});
            },
          ),
          SizedBox(
            height: 100,
            child: _buildPresetList(),
          ),
        ],
      ],
    );
  }

  Widget _buildPresetList() {
    final visible = _visiblePresets;
    if (visible.isEmpty) {
      return Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: Spacing.md,
          vertical: Spacing.sm,
        ),
        child: Row(
          children: [
            _SaveTile(onTap: _onSaveCurrent),
            const SizedBox(width: Spacing.md),
            Expanded(
              child: Text(
                'No presets in this category yet.',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
              ),
            ),
          ],
        ),
      );
    }
    return ValueListenableBuilder<AppliedPresetRecord?>(
      valueListenable: widget.session.appliedPreset,
      builder: (context, active, _) {
        return ValueListenableBuilder<ui.Image?>(
          valueListenable: widget.session.thumbnailProxy,
          builder: (context, proxyImage, _) {
            return ListView.separated(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(
                horizontal: Spacing.md,
                vertical: Spacing.sm,
              ),
              itemCount: visible.length + 1,
              separatorBuilder: (_, _) => const SizedBox(width: Spacing.sm),
              itemBuilder: (context, index) {
                if (index == visible.length) {
                  return _SaveTile(onTap: _onSaveCurrent);
                }
                final p = visible[index];
                final isActive = active?.preset.id == p.id;
                return _PresetTile(
                  preset: p,
                  proxyImage: proxyImage,
                  recipe:
                      widget.session.presetThumbnailCache.recipeFor(p),
                  isActive: isActive,
                  onTap: () => _onTileTap(p),
                  onLongPress: p.builtIn ? null : () => _onDelete(p),
                );
              },
            );
          },
        );
      },
    );
  }
}

class _CategoryRail extends StatelessWidget {
  const _CategoryRail({
    required this.selected,
    required this.onChanged,
  });

  final String? selected;
  final ValueChanged<String?> onChanged;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 36,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: Spacing.md),
        children: [
          _CategoryChip(
            label: 'All',
            selected: selected == null,
            onTap: () => onChanged(null),
          ),
          const SizedBox(width: Spacing.xs),
          for (final c in BuiltInPresets.categories) ...[
            _CategoryChip(
              label: BuiltInPresets.labelFor(c),
              selected: selected == c,
              onTap: () => onChanged(c),
            ),
            const SizedBox(width: Spacing.xs),
          ],
        ],
      ),
    );
  }
}

class _CategoryChip extends StatelessWidget {
  const _CategoryChip({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: ChoiceChip(
        label: Text(label),
        selected: selected,
        onSelected: (_) => onTap(),
        visualDensity: VisualDensity.compact,
        materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
      ),
    );
  }
}

class _PresetTile extends StatelessWidget {
  const _PresetTile({
    required this.preset,
    required this.proxyImage,
    required this.recipe,
    required this.isActive,
    required this.onTap,
    this.onLongPress,
  });

  final Preset preset;
  final ui.Image? proxyImage;
  final PresetThumbnailRecipe recipe;
  final bool isActive;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final strength = PresetMetadata.strengthOf(preset);
    return Tooltip(
      message: preset.builtIn
          ? (isActive
              ? '${preset.name}\nTap again to adjust strength'
              : preset.name)
          : '${preset.name}\nLong-press to delete',
      waitDuration: const Duration(milliseconds: 500),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          onLongPress: onLongPress,
          borderRadius: BorderRadius.circular(8),
          child: Padding(
            padding: const EdgeInsets.all(Spacing.xs),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                _PresetThumbnail(
                  preset: preset,
                  proxyImage: proxyImage,
                  recipe: recipe,
                  isActive: isActive,
                  strength: strength,
                ),
                const SizedBox(height: Spacing.xxs),
                SizedBox(
                  width: 72,
                  child: Text(
                    preset.name,
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: isActive ? theme.colorScheme.primary : null,
                      fontWeight:
                          isActive ? FontWeight.w600 : FontWeight.normal,
                    ),
                    textAlign: TextAlign.center,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    softWrap: false,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _PresetThumbnail extends StatelessWidget {
  const _PresetThumbnail({
    required this.preset,
    required this.proxyImage,
    required this.recipe,
    required this.isActive,
    required this.strength,
  });

  final Preset preset;
  final ui.Image? proxyImage;
  final PresetThumbnailRecipe recipe;
  final bool isActive;
  final PresetStrength strength;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final borderColor = isActive
        ? theme.colorScheme.primary
        : theme.colorScheme.outline.withValues(alpha: 0.3);
    final borderWidth = isActive ? 2.0 : 1.0;
    return Container(
      width: 72,
      height: 56,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: borderColor, width: borderWidth),
      ),
      clipBehavior: Clip.antiAlias,
      child: Stack(
        fit: StackFit.expand,
        children: [
          if (proxyImage == null)
            _FallbackGradient(preset: preset)
          else
            ColorFiltered(
              colorFilter: ColorFilter.matrix(recipe.colorMatrix),
              child: RawImage(
                image: proxyImage,
                fit: BoxFit.cover,
              ),
            ),
          if (recipe.hasVignette)
            IgnorePointer(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: RadialGradient(
                    radius: 0.85,
                    colors: [
                      Colors.transparent,
                      Colors.black
                          .withValues(alpha: recipe.vignetteAmount * 0.6),
                    ],
                  ),
                ),
              ),
            ),
          if (strength == PresetStrength.strong)
            Positioned(
              top: 2,
              right: 2,
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 4,
                  vertical: 1,
                ),
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.6),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: const Text(
                  'STRONG',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 7,
                    fontWeight: FontWeight.bold,
                    letterSpacing: 0.5,
                  ),
                ),
              ),
            ),
          if (preset.id == 'builtin.none')
            // The "Original" tile has no edits — overlay an explicit
            // label so it never renders as a plain grey tile.
            Positioned.fill(
              child: Container(
                alignment: Alignment.center,
                color: Colors.black.withValues(alpha: 0.15),
                child: const Text(
                  'Original',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 10,
                    fontWeight: FontWeight.w600,
                    shadows: [
                      Shadow(blurRadius: 2, color: Colors.black54),
                    ],
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _FallbackGradient extends StatelessWidget {
  const _FallbackGradient({required this.preset});
  final Preset preset;

  @override
  Widget build(BuildContext context) {
    final hash = preset.id.hashCode.abs();
    final hue = (hash % 360).toDouble();
    final top = HSVColor.fromAHSV(1, hue, 0.5, 0.65).toColor();
    final bottom =
        HSVColor.fromAHSV(1, (hue + 30) % 360, 0.4, 0.45).toColor();
    return Container(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [top, bottom],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
      ),
      child: Center(
        child: Text(
          _initialsFor(preset.name),
          style: const TextStyle(
            color: Colors.white,
            fontSize: 16,
            fontWeight: FontWeight.bold,
            shadows: [Shadow(blurRadius: 2, color: Colors.black54)],
          ),
        ),
      ),
    );
  }

  String _initialsFor(String name) {
    final parts = name.trim().split(RegExp(r'\s+'));
    if (parts.isEmpty) return '?';
    if (parts.length == 1) return parts[0].substring(0, 1).toUpperCase();
    return '${parts[0].substring(0, 1)}${parts[1].substring(0, 1)}'
        .toUpperCase();
  }
}

class _SaveTile extends StatelessWidget {
  const _SaveTile({required this.onTap});
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Tooltip(
      message: 'Save the current adjustments as a custom preset',
      waitDuration: const Duration(milliseconds: 400),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(8),
          child: Padding(
            padding: const EdgeInsets.all(Spacing.xs),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 72,
                  height: 56,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(
                      color:
                          theme.colorScheme.primary.withValues(alpha: 0.5),
                    ),
                  ),
                  child: Icon(
                    Icons.add,
                    color: theme.colorScheme.primary,
                  ),
                ),
                const SizedBox(height: Spacing.xxs),
                SizedBox(
                  width: 72,
                  child: Text(
                    'Save',
                    style: theme.textTheme.labelSmall,
                    textAlign: TextAlign.center,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _SavePresetDialog extends StatefulWidget {
  const _SavePresetDialog();

  @override
  State<_SavePresetDialog> createState() => _SavePresetDialogState();
}

class _SavePresetDialogState extends State<_SavePresetDialog> {
  final TextEditingController _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Save preset'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            controller: _controller,
            autofocus: true,
            decoration: const InputDecoration(
              labelText: 'Name',
              hintText: 'My Look',
              prefixIcon: Icon(Icons.auto_awesome_outlined),
            ),
            onSubmitted: (v) => Navigator.of(context).pop(v),
          ),
          const SizedBox(height: Spacing.md),
          Text(
            'This will save all your current adjustments. You can apply it to other photos later.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(_controller.text),
          child: const Text('Save'),
        ),
      ],
    );
  }
}

/// Bottom sheet holding the Amount slider for the currently-applied
/// preset. Renders a 0–150% slider with a live numeric readout and a
/// 100% tick mark so users can snap back to the designed strength.
///
/// Haptic ticks at every 10% give a tactile sense of the slider's
/// position without requiring the user to look at the number.
class _PresetAmountSheet extends StatefulWidget {
  const _PresetAmountSheet({
    required this.preset,
    required this.initial,
    required this.onChanged,
  });

  final Preset preset;
  final double initial;
  final ValueChanged<double> onChanged;

  @override
  State<_PresetAmountSheet> createState() => _PresetAmountSheetState();
}

class _PresetAmountSheetState extends State<_PresetAmountSheet> {
  late double _amount = widget.initial.clamp(0.0, 1.5);
  int _lastHapticTenth = -1;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final strength = PresetMetadata.strengthOf(widget.preset);
    return Padding(
      padding: EdgeInsets.only(
        left: Spacing.lg,
        right: Spacing.lg,
        bottom: MediaQuery.of(context).viewInsets.bottom + Spacing.lg,
        top: Spacing.sm,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(
                Icons.tune,
                size: 18,
                color: theme.colorScheme.primary,
              ),
              const SizedBox(width: Spacing.sm),
              Expanded(
                child: Text(
                  widget.preset.name,
                  style: theme.textTheme.titleMedium,
                ),
              ),
              if (strength == PresetStrength.strong)
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 6,
                    vertical: 2,
                  ),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.tertiaryContainer,
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Text(
                    'STRONG',
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: theme.colorScheme.onTertiaryContainer,
                      fontWeight: FontWeight.bold,
                      letterSpacing: 0.5,
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: Spacing.xs),
          Text(
            'Amount',
            style: theme.textTheme.labelMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          Row(
            children: [
              Expanded(
                child: Slider(
                  value: _amount,
                  min: 0.0,
                  max: 1.5,
                  divisions: 30,
                  label: '${(_amount * 100).round()}%',
                  onChanged: (v) {
                    setState(() => _amount = v);
                    final tenth = (v * 10).round();
                    if (tenth != _lastHapticTenth) {
                      _lastHapticTenth = tenth;
                      Haptics.tap();
                    }
                    widget.onChanged(v);
                  },
                ),
              ),
              SizedBox(
                width: 48,
                child: Text(
                  '${(_amount * 100).round()}%',
                  textAlign: TextAlign.right,
                  style: theme.textTheme.titleMedium?.copyWith(
                    color: theme.colorScheme.primary,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: Spacing.xs),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text('0%', style: theme.textTheme.labelSmall),
              Text(
                '100% (designed)',
                style: theme.textTheme.labelSmall?.copyWith(
                  color: theme.colorScheme.primary,
                ),
              ),
              Text('150%', style: theme.textTheme.labelSmall),
            ],
          ),
        ],
      ),
    );
  }
}
