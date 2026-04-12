import 'package:flutter/material.dart';

import '../../../../core/feedback/user_feedback.dart';
import '../../../../core/logging/app_logger.dart';
import '../../../../core/platform/haptics.dart';
import '../../../../core/theme/spacing.dart';
import '../../../../engine/presets/preset.dart';
import '../../../../engine/presets/preset_repository.dart';
import '../notifiers/editor_session.dart';

final _log = AppLogger('PresetStrip');

/// Horizontal scrollable strip of preset tiles under a "Presets" header.
/// Taps apply the preset atomically via [EditorSession.applyPreset];
/// long-press on a custom preset offers delete. A trailing "Save" tile
/// captures the current pipeline as a named custom preset.
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
    try {
      await _repo.delete(preset.id);
      await _reload();
      if (!mounted) return;
      Haptics.impact();
      UserFeedback.info(context, 'Preset "${preset.name}" deleted');
    } catch (e, st) {
      _log.e('delete failed', error: e, stackTrace: st);
    }
  }

  void _onApply(Preset preset) {
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
                    'Tap a preset to apply. Long-press a custom preset to delete it.',
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
        else
          SizedBox(
            height: 100,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(
                horizontal: Spacing.md,
                vertical: Spacing.sm,
              ),
              itemCount: _presets.length + 1,
              separatorBuilder: (_, _) => const SizedBox(width: Spacing.sm),
              itemBuilder: (context, index) {
                if (index == _presets.length) {
                  return _SaveTile(onTap: _onSaveCurrent);
                }
                final p = _presets[index];
                return _PresetTile(
                  preset: p,
                  onTap: () => _onApply(p),
                  onLongPress: p.builtIn ? null : () => _onDelete(p),
                );
              },
            ),
          ),
      ],
    );
  }
}

class _PresetTile extends StatelessWidget {
  const _PresetTile({
    required this.preset,
    required this.onTap,
    this.onLongPress,
  });

  final Preset preset;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Tooltip(
      message: preset.builtIn
          ? preset.name
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
                Container(
                  width: 72,
                  height: 56,
                  decoration: BoxDecoration(
                    gradient: _gradientFor(preset),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(
                      color:
                          theme.colorScheme.outline.withValues(alpha: 0.3),
                    ),
                  ),
                  child: Center(
                    child: Text(
                      _initialsFor(preset.name),
                      style: theme.textTheme.labelLarge?.copyWith(
                        color: Colors.white,
                        fontWeight: FontWeight.bold,
                        shadows: const [
                          Shadow(blurRadius: 2, color: Colors.black54),
                        ],
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: Spacing.xxs),
                SizedBox(
                  width: 72,
                  child: Text(
                    preset.name,
                    style: theme.textTheme.labelSmall,
                    textAlign: TextAlign.center,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
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

  LinearGradient _gradientFor(Preset preset) {
    // Deterministic hue from preset id, with a slight gradient so the
    // tile reads as a preview rather than a flat swatch. Real LUT-based
    // thumbnails ship in a later phase.
    final hash = preset.id.hashCode.abs();
    final hue = (hash % 360).toDouble();
    final top = HSVColor.fromAHSV(1, hue, 0.5, 0.65).toColor();
    final bottom =
        HSVColor.fromAHSV(1, (hue + 30) % 360, 0.4, 0.45).toColor();
    return LinearGradient(
      colors: [top, bottom],
      begin: Alignment.topLeft,
      end: Alignment.bottomRight,
    );
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
