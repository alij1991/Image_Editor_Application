import 'package:flutter/material.dart';

import '../../../../core/feedback/user_feedback.dart';
import '../../../../core/logging/app_logger.dart';
import '../../../../core/platform/haptics.dart';
import '../../../../core/theme/spacing.dart';
import '../../../../engine/history/history_state.dart';
import '../../../../engine/layers/content_layer.dart';
import '../../../../engine/layers/layer_blend_mode.dart';
import '../../../../engine/layers/layer_mask.dart';
import '../../../../engine/pipeline/pipeline_extensions.dart';
import '../notifiers/editor_session.dart';
import 'layer_edit_sheet.dart';

final _log = AppLogger('LayerStackPanel');

/// Panel listing every content layer in the pipeline with per-layer
/// controls: visibility toggle, opacity slider, delete, reorder via
/// drag handles.
class LayerStackPanel extends StatelessWidget {
  const LayerStackPanel({
    required this.session,
    required this.state,
    super.key,
  });

  final EditorSession session;
  final HistoryState state;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final layers = state.pipeline.contentLayers;

    if (layers.isEmpty) {
      return Padding(
        padding: const EdgeInsets.all(Spacing.lg),
        child: Column(
          children: [
            Icon(
              Icons.layers_outlined,
              size: 40,
              color: theme.colorScheme.onSurfaceVariant,
            ),
            const SizedBox(height: Spacing.sm),
            Text(
              'No layers yet',
              style: theme.textTheme.titleSmall,
            ),
            const SizedBox(height: Spacing.xs),
            Text(
              'Use the Add button in the top bar to place text, stickers, or drawings.',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      );
    }

    // Paint order in our pipeline is bottom → top; the UI convention is
    // top → bottom, so we reverse for display.
    final reversed = layers.reversed.toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(
            Spacing.lg,
            Spacing.sm,
            Spacing.lg,
            Spacing.xs,
          ),
          child: Row(
            children: [
              Text(
                'LAYERS',
                style: theme.textTheme.labelSmall?.copyWith(
                  color: theme.colorScheme.primary,
                  letterSpacing: 1.2,
                ),
              ),
              const SizedBox(width: Spacing.xs),
              Tooltip(
                message:
                    'Drag to reorder. Tap the eye to hide, or the trash to delete.',
                child: Icon(
                  Icons.help_outline,
                  size: 14,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
        ReorderableListView.builder(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          buildDefaultDragHandles: false,
          itemCount: reversed.length,
          onReorder: (oldIndex, newIndex) {
            // ReorderableListView reports newIndex as a pre-insertion
            // index. Normalize the post-move display index first.
            if (newIndex > oldIndex) newIndex--;
            final displayFrom = oldIndex;
            final displayTo = newIndex;
            // The list is displayed TOP→BOTTOM but the pipeline is
            // BOTTOM→TOP (paint order), so reverse the display index
            // back into a layer-space index before calling the session.
            final layerCount = reversed.length;
            final paintFrom = layerCount - 1 - displayFrom;
            final paintTo = layerCount - 1 - displayTo;
            _log.i('reorder', {
              'layerId': reversed[displayFrom].id,
              'paintFrom': paintFrom,
              'paintTo': paintTo,
            });
            Haptics.tap();
            session.reorderLayer(reversed[displayFrom].id, paintTo);
          },
          itemBuilder: (context, index) {
            final layer = reversed[index];
            return _LayerTile(
              key: ValueKey(layer.id),
              index: index,
              layer: layer,
              onToggleVisibility: () {
                _log.i('toggle visibility', {'id': layer.id});
                Haptics.tap();
                session.toggleLayerVisibility(layer.id);
              },
              onDelete: () {
                _log.i('delete requested', {'id': layer.id});
                Haptics.impact();
                session.deleteLayer(layer.id);
                // Hint at undo so the user knows the action is
                // recoverable — matches the way Lightroom / Photos
                // surface destructive actions.
                UserFeedback.info(
                    context, 'Deleted ${layer.displayLabel} — undo available');
              },
              // During drag: ephemeral preview, no history entry.
              onOpacityPreview: (v) {
                session.previewLayer(_withOpacity(layer, v));
              },
              // On release: commit one history entry.
              onOpacityCommitted: (v) {
                session.updateLayer(_withOpacity(layer, v));
              },
              onEdit: () => _editLayer(context, layer),
            );
          },
        ),
      ],
    );
  }

  ContentLayer _withOpacity(ContentLayer layer, double opacity) {
    switch (layer) {
      case TextLayer():
        return layer.copyWith(opacity: opacity);
      case StickerLayer():
        return layer.copyWith(opacity: opacity);
      case DrawingLayer():
        return layer.copyWith(opacity: opacity);
      case AdjustmentLayer():
        return layer.copyWith(opacity: opacity);
    }
  }

  Future<void> _editLayer(BuildContext context, ContentLayer layer) async {
    _log.i('edit tapped', {'id': layer.id, 'kind': layer.kind.name});
    Haptics.tap();
    // Ephemeral preview while the sheet is open; commit once on save.
    // Back-button / swipe cancel triggers cancelLayerPreview via the
    // sheet's `onCancel` callback.
    final result = await LayerEditSheet.show(
      context,
      layer: layer,
      onPreview: session.previewLayer,
      onCancel: session.cancelLayerPreview,
    );
    if (result != null) {
      session.updateLayer(result);
    }
  }
}

class _LayerTile extends StatelessWidget {
  const _LayerTile({
    required this.index,
    required this.layer,
    required this.onToggleVisibility,
    required this.onDelete,
    required this.onOpacityPreview,
    required this.onOpacityCommitted,
    required this.onEdit,
    super.key,
  });

  final int index;
  final ContentLayer layer;
  final VoidCallback onToggleVisibility;
  final VoidCallback onDelete;
  final ValueChanged<double> onOpacityPreview;
  final ValueChanged<double> onOpacityCommitted;
  final VoidCallback onEdit;

  IconData get _kindIcon {
    switch (layer.kind) {
      case LayerKind.text:
        return Icons.title;
      case LayerKind.sticker:
        return Icons.emoji_emotions_outlined;
      case LayerKind.drawing:
        return Icons.brush_outlined;
      case LayerKind.adjustment:
        return Icons.auto_awesome_outlined;
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      key: ValueKey('layer-tile-${layer.id}'),
      padding: const EdgeInsets.symmetric(
        horizontal: Spacing.lg,
        vertical: Spacing.xs,
      ),
      child: Material(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(8),
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: Spacing.sm,
            vertical: Spacing.sm,
          ),
          child: Row(
            children: [
              ReorderableDragStartListener(
                index: index,
                child: Icon(
                  Icons.drag_indicator,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(width: Spacing.sm),
              Icon(_kindIcon, size: 20),
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
                            layer.displayLabel,
                            style: theme.textTheme.bodyMedium,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        if (layer.blendMode != LayerBlendMode.normal ||
                            !layer.mask.isIdentity) ...[
                          const SizedBox(width: Spacing.xs),
                          _BlendMaskBadge(layer: layer),
                        ],
                      ],
                    ),
                    _LayerOpacitySlider(
                      initialValue: layer.opacity,
                      onPreview: onOpacityPreview,
                      onCommit: onOpacityCommitted,
                    ),
                  ],
                ),
              ),
              IconButton(
                tooltip: 'Edit blend / mask',
                icon: const Icon(Icons.tune),
                onPressed: onEdit,
              ),
              IconButton(
                tooltip: layer.visible ? 'Hide' : 'Show',
                icon: Icon(
                  layer.visible
                      ? Icons.visibility_outlined
                      : Icons.visibility_off_outlined,
                ),
                onPressed: onToggleVisibility,
              ),
              IconButton(
                tooltip: 'Delete',
                icon: const Icon(Icons.delete_outline),
                onPressed: onDelete,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Slider that holds its own live value so drag ticks update smoothly
/// without re-reading the committed pipeline. Fires [onPreview] on
/// every change (ephemeral) and [onCommit] on release (one history
/// entry).
class _LayerOpacitySlider extends StatefulWidget {
  const _LayerOpacitySlider({
    required this.initialValue,
    required this.onPreview,
    required this.onCommit,
  });

  final double initialValue;
  final ValueChanged<double> onPreview;
  final ValueChanged<double> onCommit;

  @override
  State<_LayerOpacitySlider> createState() => _LayerOpacitySliderState();
}

class _LayerOpacitySliderState extends State<_LayerOpacitySlider> {
  late double _value;

  @override
  void initState() {
    super.initState();
    _value = widget.initialValue;
  }

  @override
  void didUpdateWidget(covariant _LayerOpacitySlider oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Sync when the external (committed) value changes, unless the
    // user is mid-drag (in which case _value is the source of truth).
    if (oldWidget.initialValue != widget.initialValue) {
      _value = widget.initialValue;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Slider(
      value: _value.clamp(0.0, 1.0),
      min: 0,
      max: 1,
      label: '${(_value * 100).round()}%',
      onChanged: (v) {
        setState(() => _value = v);
        widget.onPreview(v);
      },
      onChangeEnd: widget.onCommit,
    );
  }
}

/// Tiny badge chip shown on a layer tile when the layer has a
/// non-default blend mode or an active mask. Helps users recognize
/// at a glance which layers have special settings.
class _BlendMaskBadge extends StatelessWidget {
  const _BlendMaskBadge({required this.layer});

  final ContentLayer layer;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final parts = <String>[];
    if (layer.blendMode != LayerBlendMode.normal) {
      parts.add(layer.blendMode.label);
    }
    if (!layer.mask.isIdentity) {
      parts.add(layer.mask.shape.label);
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: theme.colorScheme.secondaryContainer,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Text(
        parts.join(' • '),
        style: theme.textTheme.labelSmall?.copyWith(
          color: theme.colorScheme.onSecondaryContainer,
          fontSize: 10,
        ),
      ),
    );
  }
}
