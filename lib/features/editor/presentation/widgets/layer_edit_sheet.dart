import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../../core/logging/app_logger.dart';
import '../../../../core/platform/haptics.dart';
import '../../../../core/theme/spacing.dart';
import '../../../../engine/layers/content_layer.dart';
import '../../../../engine/layers/layer_blend_mode.dart';
import '../../../../engine/layers/layer_mask.dart';

final _log = AppLogger('LayerEditSheet');

/// Modal sheet for editing a content layer's blend mode + procedural
/// mask. Opens from the layer stack panel's "Edit" button.
///
/// ## Ephemeral-preview contract
///
/// The sheet holds a local `_draft` and calls [onPreview] on every
/// change. The caller should wire [onPreview] to an ephemeral update
/// path (e.g. `EditorSession.previewLayer`) that bypasses history.
///
/// - **Save** → the sheet pops with `_draft`. The parent commits it
///   via `session.updateLayer(result)` — **one** history entry.
/// - **Cancel** (button, back, or swipe) → the sheet pops with `null`
///   AND calls [onCancel] so the parent can revert the preview via
///   `session.cancelLayerPreview`.
class LayerEditSheet extends StatefulWidget {
  const LayerEditSheet({
    required this.layer,
    required this.onPreview,
    required this.onCancel,
    super.key,
  });

  final ContentLayer layer;

  /// Called on every draft change with the draft layer so the canvas
  /// can live-preview without polluting history.
  final ValueChanged<ContentLayer> onPreview;

  /// Called when the user cancels (including via back-button or swipe
  /// dismiss) so the parent can revert the preview.
  final VoidCallback onCancel;

  static Future<ContentLayer?> show(
    BuildContext context, {
    required ContentLayer layer,
    required ValueChanged<ContentLayer> onPreview,
    required VoidCallback onCancel,
  }) {
    return showModalBottomSheet<ContentLayer>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (_) => LayerEditSheet(
        layer: layer,
        onPreview: onPreview,
        onCancel: onCancel,
      ),
    );
  }

  @override
  State<LayerEditSheet> createState() => _LayerEditSheetState();
}

class _LayerEditSheetState extends State<LayerEditSheet> {
  late ContentLayer _draft;
  bool _cancelFired = false;

  @override
  void initState() {
    super.initState();
    _draft = widget.layer;
    _log.i('opened', {
      'id': widget.layer.id,
      'kind': widget.layer.kind.name,
      'blendMode': widget.layer.blendMode.name,
      'maskShape': widget.layer.mask.shape.name,
    });
  }

  void _update(ContentLayer Function(ContentLayer) mutate) {
    setState(() => _draft = mutate(_draft));
    widget.onPreview(_draft);
  }

  void _setBlendMode(LayerBlendMode mode) {
    _log.d('blend mode', {'mode': mode.name});
    Haptics.tap();
    _update((l) => _withBlendMode(l, mode));
  }

  void _setMaskShape(MaskShape shape) {
    _log.d('mask shape', {'shape': shape.name});
    Haptics.tap();
    final nextMask = _draft.mask.copyWith(shape: shape);
    _update((l) => _withMask(l, nextMask));
  }

  void _setMaskField(LayerMask Function(LayerMask) mutate) {
    _update((l) => _withMask(l, mutate(l.mask)));
  }

  ContentLayer _withBlendMode(ContentLayer layer, LayerBlendMode mode) {
    switch (layer) {
      case TextLayer():
        return layer.copyWith(blendMode: mode);
      case StickerLayer():
        return layer.copyWith(blendMode: mode);
      case DrawingLayer():
        return layer.copyWith(blendMode: mode);
      case AdjustmentLayer():
        return layer.copyWith(blendMode: mode);
    }
  }

  ContentLayer _withMask(ContentLayer layer, LayerMask mask) {
    switch (layer) {
      case TextLayer():
        return layer.copyWith(mask: mask);
      case StickerLayer():
        return layer.copyWith(mask: mask);
      case DrawingLayer():
        return layer.copyWith(mask: mask);
      case AdjustmentLayer():
        return layer.copyWith(mask: mask);
    }
  }

  void _save() {
    _log.i('save', {
      'blendMode': _draft.blendMode.name,
      'maskShape': _draft.mask.shape.name,
    });
    Haptics.impact();
    Navigator.of(context).pop(_draft);
  }

  void _cancel() {
    if (_cancelFired) return;
    _cancelFired = true;
    _log.i('cancel');
    widget.onCancel();
    // Navigate only if we're still mounted (covers the double-cancel
    // race between explicit button + back-button).
    if (Navigator.of(context).canPop()) {
      Navigator.of(context).pop();
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) return;
        // Back-button / swipe dismiss — revert the preview and close.
        _cancel();
      },
      child: Padding(
        padding: EdgeInsets.only(
          bottom: MediaQuery.viewInsetsOf(context).bottom,
        ),
        child: SingleChildScrollView(
          child: Padding(
            padding: const EdgeInsets.all(Spacing.lg),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        'Edit ${_draft.displayLabel}',
                        style: theme.textTheme.titleLarge,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    IconButton(
                      tooltip: 'Cancel',
                      icon: const Icon(Icons.close),
                      onPressed: _cancel,
                    ),
                  ],
                ),
                const SizedBox(height: Spacing.md),

                // Blend mode picker
                Text('BLEND MODE',
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: theme.colorScheme.primary,
                      letterSpacing: 1.2,
                    )),
                const SizedBox(height: Spacing.sm),
                Wrap(
                  spacing: Spacing.sm,
                  runSpacing: Spacing.sm,
                  children: [
                    for (final mode in LayerBlendMode.values)
                      ChoiceChip(
                        label: Text(mode.label),
                        selected: _draft.blendMode == mode,
                        onSelected: (_) => _setBlendMode(mode),
                      ),
                  ],
                ),
                const SizedBox(height: Spacing.lg),

                // Mask shape picker
                Row(
                  children: [
                    Text('MASK',
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: theme.colorScheme.primary,
                          letterSpacing: 1.2,
                        )),
                    const SizedBox(width: Spacing.xs),
                    Tooltip(
                      message:
                          'A mask limits where the layer is visible. Gradient masks fade the layer along a line or from a point.',
                      child: Icon(
                        Icons.help_outline,
                        size: 14,
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: Spacing.sm),
                Wrap(
                  spacing: Spacing.sm,
                  children: [
                    for (final shape in MaskShape.values)
                      ChoiceChip(
                        label: Text(shape.label),
                        selected: _draft.mask.shape == shape,
                        onSelected: (_) => _setMaskShape(shape),
                      ),
                  ],
                ),
                if (_draft.mask.shape != MaskShape.none) ...[
                  const SizedBox(height: Spacing.md),
                  _MaskControls(
                    mask: _draft.mask,
                    onChanged: _setMaskField,
                  ),
                ],
                const SizedBox(height: Spacing.xl),

                Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    TextButton(
                      onPressed: _cancel,
                      child: const Text('Cancel'),
                    ),
                    const SizedBox(width: Spacing.sm),
                    FilledButton.icon(
                      icon: const Icon(Icons.check),
                      label: const Text('Save'),
                      onPressed: _save,
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Sliders for the current mask shape. Callers pass a mutator that
/// receives a `LayerMask` and returns a new one — same pattern as
/// `_setMaskField` in [_LayerEditSheetState].
class _MaskControls extends StatelessWidget {
  const _MaskControls({required this.mask, required this.onChanged});

  final LayerMask mask;
  final void Function(LayerMask Function(LayerMask)) onChanged;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        _sliderRow(
          context,
          label: 'Position X',
          value: mask.cx,
          min: 0,
          max: 1,
          format: (v) => v.toStringAsFixed(2),
          onChanged: (v) => onChanged((m) => m.copyWith(cx: v)),
        ),
        _sliderRow(
          context,
          label: 'Position Y',
          value: mask.cy,
          min: 0,
          max: 1,
          format: (v) => v.toStringAsFixed(2),
          onChanged: (v) => onChanged((m) => m.copyWith(cy: v)),
        ),
        _sliderRow(
          context,
          label: 'Feather',
          value: mask.feather,
          min: 0,
          max: 1,
          format: (v) => v.toStringAsFixed(2),
          onChanged: (v) => onChanged((m) => m.copyWith(feather: v)),
        ),
        if (mask.shape == MaskShape.linear)
          _sliderRow(
            context,
            label: 'Angle',
            value: mask.angle,
            min: -math.pi,
            max: math.pi,
            format: (v) => '${(v * 180 / math.pi).toStringAsFixed(0)}°',
            onChanged: (v) => onChanged((m) => m.copyWith(angle: v)),
          ),
        if (mask.shape == MaskShape.radial) ...[
          _sliderRow(
            context,
            label: 'Inner radius',
            value: mask.innerRadius,
            min: 0,
            max: 1,
            format: (v) => v.toStringAsFixed(2),
            // Clamp the inner radius so it stays below the outer by a
            // small epsilon — prevents the gradient from collapsing.
            onChanged: (v) => onChanged(
              (m) => m.copyWith(
                innerRadius: math.min(v, m.outerRadius - 0.02),
              ),
            ),
          ),
          _sliderRow(
            context,
            label: 'Outer radius',
            value: mask.outerRadius,
            min: 0,
            max: 1,
            format: (v) => v.toStringAsFixed(2),
            // Clamp outer to stay above inner.
            onChanged: (v) => onChanged(
              (m) => m.copyWith(
                outerRadius: math.max(v, m.innerRadius + 0.02),
              ),
            ),
          ),
        ],
        Padding(
          padding: const EdgeInsets.symmetric(vertical: Spacing.xs),
          child: SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Invert mask'),
            subtitle: Text(
              'Swap visible and hidden regions',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            value: mask.inverted,
            onChanged: (v) => onChanged((m) => m.copyWith(inverted: v)),
          ),
        ),
      ],
    );
  }

  Widget _sliderRow(
    BuildContext context, {
    required String label,
    required double value,
    required double min,
    required double max,
    required String Function(double) format,
    required ValueChanged<double> onChanged,
  }) {
    final theme = Theme.of(context);
    return Row(
      children: [
        SizedBox(
          width: 100,
          child: Text(label, style: theme.textTheme.labelMedium),
        ),
        Expanded(
          child: Slider(
            value: value.clamp(min, max),
            min: min,
            max: max,
            onChanged: onChanged,
            label: format(value),
          ),
        ),
        SizedBox(
          width: 48,
          child: Text(
            format(value),
            style: theme.textTheme.bodySmall,
            textAlign: TextAlign.end,
          ),
        ),
      ],
    );
  }
}
