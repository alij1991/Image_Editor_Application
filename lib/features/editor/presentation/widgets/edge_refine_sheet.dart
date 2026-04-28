import 'package:flutter/material.dart';

import '../../../../core/logging/app_logger.dart';
import '../../../../core/platform/haptics.dart';
import '../../../../core/theme/spacing.dart';
import '../../../../engine/layers/content_layer.dart';
import '../notifiers/editor_session.dart';

final _log = AppLogger('EdgeRefineSheet');

/// Phase XVI.15 → XVI.20 — modal slider for softening the edge of a
/// compose-subject layer.
///
/// XVI.15 shipped two sliders (Feather + Decontaminate). XVI.20 dropped
/// the second: RVM's near-binary matte makes the visible decontam
/// surface area tiny, and the slider was indistinguishable from a
/// no-op. Decontaminate still runs as an internal pass inside
/// `ComposeEdgeRefine.apply` whenever feather > 0 — it just has no
/// user-facing knob.
///
/// UX: each slider drag updates the working pipeline + re-bakes the
/// cached subject bitmap so the canvas previews live; on release it
/// commits to history via [EditorSession.flushLayerTransform]. No
/// Save/Cancel — every gesture end is already a history entry, and
/// the user reverts via standard Undo. A `hasRaw == false` layer
/// (e.g. restored from a persisted pipeline without raw pixels in
/// memory) renders a disabled slider with a "re-run compose to soften
/// edges" tip.
class EdgeRefineSheet extends StatefulWidget {
  const EdgeRefineSheet({
    required this.session,
    required this.layer,
    required this.hasRaw,
    super.key,
  });

  final EditorSession session;
  final AdjustmentLayer layer;
  final bool hasRaw;

  static Future<void> show(
    BuildContext context, {
    required EditorSession session,
    required AdjustmentLayer layer,
    required bool hasRaw,
  }) {
    // Phase XVI.16 — non-blocking sheet: `barrierColor: transparent`
    // + compact height so the canvas behind stays visible and the
    // user can see the feather change render live.
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      barrierColor: Colors.transparent,
      builder: (_) => EdgeRefineSheet(
        session: session,
        layer: layer,
        hasRaw: hasRaw,
      ),
    );
  }

  @override
  State<EdgeRefineSheet> createState() => _EdgeRefineSheetState();
}

class _EdgeRefineSheetState extends State<EdgeRefineSheet> {
  late double _feather;

  @override
  void initState() {
    super.initState();
    _feather = widget.layer.edgeFeatherPx;
    _log.i('opened', {
      'id': widget.layer.id,
      'feather': _feather,
      'hasRaw': widget.hasRaw,
    });
  }

  Future<void> _pushPreview(double feather) async {
    await widget.session.updateComposeSubjectEdgeRefine(
      widget.layer.id,
      featherPx: feather,
    );
  }

  void _commit() {
    Haptics.tap();
    widget.session.flushLayerTransform();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: EdgeInsets.only(
        bottom: MediaQuery.viewInsetsOf(context).bottom,
      ),
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
                    'Soften edges',
                    style: theme.textTheme.titleLarge,
                  ),
                ),
                IconButton(
                  tooltip: 'Done',
                  icon: const Icon(Icons.check),
                  onPressed: () => Navigator.of(context).pop(),
                ),
              ],
            ),
            const SizedBox(height: Spacing.sm),
            Text(
              widget.hasRaw
                  ? 'Feather softens the cut-out edge so the subject blends into the new background.'
                  : 'Re-run compose on this photo to soften edges — the raw subject pixels were freed on session reload.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: Spacing.lg),
            _sliderRow(
              context,
              label: 'Feather',
              value: _feather,
              min: 0,
              max: 12,
              format: (v) => '${v.toStringAsFixed(1)} px',
              enabled: widget.hasRaw,
              onChanged: (v) {
                setState(() => _feather = v);
                _pushPreview(v);
              },
              onChangeEnd: (_) => _commit(),
            ),
            const SizedBox(height: Spacing.md),
          ],
        ),
      ),
    );
  }

  Widget _sliderRow(
    BuildContext context, {
    required String label,
    required double value,
    required double min,
    required double max,
    required String Function(double) format,
    required bool enabled,
    required ValueChanged<double> onChanged,
    required ValueChanged<double> onChangeEnd,
  }) {
    final theme = Theme.of(context);
    return Row(
      children: [
        SizedBox(
          width: 120,
          child: Text(label, style: theme.textTheme.labelMedium),
        ),
        Expanded(
          child: Slider(
            value: value.clamp(min, max),
            min: min,
            max: max,
            onChanged: enabled ? onChanged : null,
            onChangeEnd: enabled ? onChangeEnd : null,
            label: format(value),
          ),
        ),
        SizedBox(
          width: 60,
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
