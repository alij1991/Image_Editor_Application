import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../../../core/logging/app_logger.dart';
import '../../../../core/platform/haptics.dart';
import '../../../../core/theme/spacing.dart';
import '../../../../engine/history/history_event.dart';
import '../../../../engine/history/history_manager.dart';
import '../../../../engine/pipeline/edit_op_type.dart';
import '../../../../engine/pipeline/op_spec.dart';
import '../notifiers/editor_session.dart';

final _log = AppLogger('HistoryTimeline');

/// Bottom sheet that lists every entry in the editor's history with a
/// label, relative timestamp, and a tap-to-jump action. The current
/// cursor is highlighted; jumping to a different entry dispatches
/// `JumpToEntry` on the bloc and pops the sheet.
///
/// Used as a power-user surface — for the common case of step-by-step
/// undo, the app-bar arrow buttons stay simpler. The timeline shines
/// when the user wants to go back many steps without spamming undo or
/// when they need to inspect what's in their history.
class HistoryTimelineSheet extends StatelessWidget {
  const HistoryTimelineSheet({required this.session, super.key});

  final EditorSession session;

  static Future<void> show(BuildContext context, EditorSession session) {
    _log.i('opened');
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (_) => HistoryTimelineSheet(session: session),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final manager = session.historyManager;
    final entries = manager.entries;
    final cursor = manager.cursor;

    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.of(context).size.height * 0.7,
        ),
        child: Padding(
          padding: const EdgeInsets.all(Spacing.lg),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Text('History', style: theme.textTheme.titleLarge),
                  const SizedBox(width: Spacing.sm),
                  Text(
                    '${entries.length} entr${entries.length == 1 ? "y" : "ies"}',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
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
              if (entries.isEmpty)
                _EmptyState(theme: theme)
              else
                Flexible(
                  child: ListView.separated(
                    shrinkWrap: true,
                    itemCount: entries.length + 1,
                    separatorBuilder: (_, _) => const SizedBox(height: 4),
                    itemBuilder: (context, displayIndex) {
                      // Display order: newest first. The "Original"
                      // pseudo-entry sits at the bottom so the user can
                      // jump all the way back.
                      if (displayIndex == entries.length) {
                        return _TimelineRow(
                          label: 'Original',
                          subtitle: 'Before any edits',
                          timestamp: null,
                          isCurrent: cursor == -1,
                          icon: Icons.image_outlined,
                          onTap: cursor == -1
                              ? null
                              : () => _jumpTo(context, -1),
                        );
                      }
                      final entryIdx = entries.length - 1 - displayIndex;
                      final entry = entries[entryIdx];
                      return _TimelineRow(
                        label: _opLabelOrFallback(entry.op.type),
                        subtitle: _summary(entry),
                        timestamp: entry.timestamp,
                        isCurrent: entryIdx == cursor,
                        icon: _iconFor(entry.op.type),
                        onTap: entryIdx == cursor
                            ? null
                            : () => _jumpTo(context, entryIdx),
                      );
                    },
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  void _jumpTo(BuildContext context, int index) {
    _log.i('jump', {'index': index});
    Haptics.tap();
    session.historyBloc.add(JumpToEntry(index));
    Navigator.of(context).pop();
  }

  /// One-line summary of what an entry changed. Surfaces the
  /// op-specific scalar value when there is one (most slider commits),
  /// otherwise falls back to the param dump.
  static String _summary(HistoryEntry entry) {
    final params = entry.op.parameters;
    if (params.isEmpty) return '';
    if (params.length == 1) {
      final v = params.values.first;
      if (v is num) return v.toStringAsFixed(2);
      return v.toString();
    }
    // Multi-param: show keys joined.
    return params.keys.take(4).join(', ');
  }

  static IconData _iconFor(String type) {
    if (type.startsWith('color.')) return Icons.palette_outlined;
    if (type.startsWith('fx.')) return Icons.auto_awesome_outlined;
    if (type.startsWith('blur.')) return Icons.blur_on;
    if (type.startsWith('noise.')) return Icons.grain;
    if (type.startsWith('geom.')) return Icons.crop;
    if (type.startsWith('layer.')) return Icons.layers_outlined;
    if (type.startsWith('ai.')) return Icons.auto_fix_high;
    if (type.startsWith('filter.')) return Icons.tune;
    if (type == 'preset.apply') return Icons.style;
    return Icons.adjust;
  }
}

class _TimelineRow extends StatelessWidget {
  const _TimelineRow({
    required this.label,
    required this.subtitle,
    required this.timestamp,
    required this.isCurrent,
    required this.icon,
    required this.onTap,
  });

  final String label;
  final String subtitle;
  final DateTime? timestamp;
  final bool isCurrent;
  final IconData icon;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = isCurrent
        ? theme.colorScheme.primary
        : theme.colorScheme.onSurface;
    return Material(
      color: isCurrent
          ? theme.colorScheme.primaryContainer.withValues(alpha: 0.4)
          : theme.colorScheme.surfaceContainerHighest,
      borderRadius: BorderRadius.circular(8),
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: Spacing.sm,
            vertical: Spacing.sm,
          ),
          child: Row(
            children: [
              Icon(icon, color: color, size: 20),
              const SizedBox(width: Spacing.sm),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            label,
                            style: theme.textTheme.bodyMedium?.copyWith(
                              color: color,
                              fontWeight: isCurrent
                                  ? FontWeight.w600
                                  : FontWeight.w500,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        if (isCurrent) ...[
                          const SizedBox(width: Spacing.xs),
                          Icon(Icons.check, color: color, size: 14),
                        ],
                      ],
                    ),
                    if (subtitle.isNotEmpty)
                      Text(
                        subtitle,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                          fontFeatures: const [FontFeature.tabularFigures()],
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                  ],
                ),
              ),
              if (timestamp != null)
                Text(
                  _shortRelative(timestamp!),
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  /// "5s", "2m", "1h", "3d" — compact relative timestamp readable in
  /// the right margin without taking much room.
  static String _shortRelative(DateTime ts) {
    final delta = DateTime.now().difference(ts);
    if (delta.inSeconds < 60) return '${delta.inSeconds}s';
    if (delta.inMinutes < 60) return '${delta.inMinutes}m';
    if (delta.inHours < 24) return '${delta.inHours}h';
    if (delta.inDays < 7) return '${delta.inDays}d';
    return DateFormat.MMMd().format(ts);
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({required this.theme});
  final ThemeData theme;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: Spacing.xl),
      child: Column(
        children: [
          Icon(
            Icons.history,
            size: 36,
            color: theme.colorScheme.onSurfaceVariant,
          ),
          const SizedBox(height: Spacing.sm),
          Text('No edits yet', style: theme.textTheme.titleSmall),
          const SizedBox(height: Spacing.xs),
          Text(
            'Drag a slider, apply a preset, or add a layer — every edit '
            'shows up here so you can jump back to any point.',
            textAlign: TextAlign.center,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}

/// Friendly user-facing label for an op type. Mirrors editor_page's
/// own _opLabel — kept private to that file so the timeline duplicates
/// just enough to stand on its own without cross-file coupling.
String _opLabelOrFallback(String type) {
  final spec = OpSpecs.byType(type);
  if (spec != null) return spec.label;
  switch (type) {
    case EditOpType.crop:
      return 'Crop';
    case EditOpType.rotate:
      return 'Rotate';
    case EditOpType.flip:
      return 'Flip';
    case EditOpType.straighten:
      return 'Straighten';
    case EditOpType.perspective:
      return 'Perspective';
    case EditOpType.text:
      return 'Text layer';
    case EditOpType.sticker:
      return 'Sticker';
    case EditOpType.drawing:
      return 'Drawing';
    case EditOpType.adjustmentLayer:
      return 'Adjustment';
    case EditOpType.aiBackgroundRemoval:
      return 'Remove background';
    case EditOpType.aiInpaint:
      return 'Inpaint';
    case EditOpType.aiSuperResolution:
      return 'Super-resolution';
    case EditOpType.aiStyleTransfer:
      return 'Style transfer';
    case EditOpType.aiFaceBeautify:
      return 'Beautify';
    case EditOpType.aiSkyReplace:
      return 'Replace sky';
    case EditOpType.lut3d:
      return 'LUT';
    case EditOpType.matrixPreset:
      return 'Preset';
    case 'preset.apply':
      return 'Preset';
  }
  final last = type.split('.').last;
  if (last.isEmpty) return 'Edit';
  return last[0].toUpperCase() + last.substring(1);
}
