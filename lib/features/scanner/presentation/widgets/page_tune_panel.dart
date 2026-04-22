import 'package:flutter/material.dart';

import '../../../../core/platform/haptics.dart';
import '../../../../core/theme/spacing.dart';
import '../../application/providers.dart';
import '../../domain/models/scan_models.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Per-page fine-tune sliders that ride on top of the chosen filter.
/// Hidden behind an ExpansionTile so it doesn't permanently steal
/// canvas space — most pages don't need adjustment, but when they do
/// the user can fix a too-dark B&W or a drifted magic-color result
/// without leaving the scanner.
///
/// Each slider commits live (the notifier's two-tier render gives
/// instant preview feedback) and pushes a SINGLE undo snapshot at
/// the start of the drag — so one undo step rolls back the whole
/// gesture instead of every drag-frame.
class PageTunePanel extends ConsumerStatefulWidget {
  const PageTunePanel({required this.page, super.key});

  final ScanPage page;

  @override
  ConsumerState<PageTunePanel> createState() => _PageTunePanelState();
}

class _PageTunePanelState extends ConsumerState<PageTunePanel> {
  bool _gestureSnapshotted = false;

  void _onChangeStart() {
    if (_gestureSnapshotted) return;
    _gestureSnapshotted = true;
    ref.read(scannerNotifierProvider.notifier).beginPageAdjustmentGesture();
  }

  void _onChangeEnd() {
    _gestureSnapshotted = false;
    Haptics.tap();
  }

  void _reset() {
    Haptics.tap();
    ref.read(scannerNotifierProvider.notifier).beginPageAdjustmentGesture();
    ref.read(scannerNotifierProvider.notifier).setPageAdjustment(
          widget.page.id,
          brightness: 0,
          contrast: 0,
          thresholdOffset: 0,
          magicScale: 220,
        );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isBw = widget.page.filter == ScanFilter.bw;
    final isMagic = widget.page.filter == ScanFilter.magicColor;
    final dirty = widget.page.brightness != 0 ||
        widget.page.contrast != 0 ||
        widget.page.thresholdOffset != 0 ||
        widget.page.magicScale != 220;
    return Material(
      color: theme.colorScheme.surfaceContainerHighest,
      borderRadius: BorderRadius.circular(12),
      child: ExpansionTile(
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.all(Radius.circular(12)),
        ),
        collapsedShape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.all(Radius.circular(12)),
        ),
        leading: Icon(
          Icons.tune,
          color: dirty ? theme.colorScheme.primary : null,
        ),
        title: Row(
          children: [
            const Text('Tune'),
            if (dirty) ...[
              const SizedBox(width: Spacing.sm),
              Container(
                width: 8,
                height: 8,
                decoration: BoxDecoration(
                  color: theme.colorScheme.primary,
                  shape: BoxShape.circle,
                ),
              ),
            ],
          ],
        ),
        trailing: dirty
            ? IconButton(
                tooltip: 'Reset Tune',
                icon: const Icon(Icons.restart_alt),
                onPressed: _reset,
              )
            : null,
        childrenPadding: const EdgeInsets.fromLTRB(
          Spacing.lg,
          0,
          Spacing.lg,
          Spacing.md,
        ),
        children: [
          _SliderRow(
            label: 'Brightness',
            value: widget.page.brightness,
            min: -1,
            max: 1,
            onStart: _onChangeStart,
            onEnd: _onChangeEnd,
            onChanged: (v) {
              ref
                  .read(scannerNotifierProvider.notifier)
                  .setPageAdjustment(widget.page.id, brightness: v);
            },
          ),
          _SliderRow(
            label: 'Contrast',
            value: widget.page.contrast,
            min: -1,
            max: 1,
            disabled: isBw,
            disabledHint: 'B&W is binary — contrast has no effect.',
            onStart: _onChangeStart,
            onEnd: _onChangeEnd,
            onChanged: (v) {
              ref
                  .read(scannerNotifierProvider.notifier)
                  .setPageAdjustment(widget.page.id, contrast: v);
            },
          ),
          if (isBw)
            _SliderRow(
              label: 'Threshold',
              value: widget.page.thresholdOffset,
              min: -30,
              max: 30,
              fractionDigits: 0,
              onStart: _onChangeStart,
              onEnd: _onChangeEnd,
              onChanged: (v) {
                ref
                    .read(scannerNotifierProvider.notifier)
                    .setPageAdjustment(widget.page.id,
                        thresholdOffset: v);
              },
            ),
          if (isMagic)
            _SliderRow(
              label: 'Intensity',
              value: widget.page.magicScale,
              min: 180,
              max: 240,
              identity: 220,
              fractionDigits: 0,
              onStart: _onChangeStart,
              onEnd: _onChangeEnd,
              onChanged: (v) {
                ref
                    .read(scannerNotifierProvider.notifier)
                    .setPageAdjustment(widget.page.id, magicScale: v);
              },
            ),
        ],
      ),
    );
  }
}

class _SliderRow extends StatelessWidget {
  const _SliderRow({
    required this.label,
    required this.value,
    required this.min,
    required this.max,
    required this.onStart,
    required this.onChanged,
    required this.onEnd,
    this.disabled = false,
    this.disabledHint,
    this.fractionDigits = 2,
    this.identity = 0,
  });

  final String label;
  final double value;
  final double min;
  final double max;
  final double identity;
  final bool disabled;
  final String? disabledHint;
  final int fractionDigits;
  final VoidCallback onStart;
  final ValueChanged<double> onChanged;
  final VoidCallback onEnd;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isIdentity = value == identity;
    return Padding(
      padding: const EdgeInsets.only(bottom: Spacing.xs),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  label,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: disabled
                        ? theme.colorScheme.onSurface.withValues(alpha: 0.4)
                        : null,
                  ),
                ),
              ),
              Text(
                isIdentity ? '–' : value.toStringAsFixed(fractionDigits),
                style: theme.textTheme.bodySmall?.copyWith(
                  color: disabled
                      ? theme.colorScheme.onSurface.withValues(alpha: 0.4)
                      : theme.colorScheme.primary,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
            ],
          ),
          Slider(
            value: value.clamp(min, max),
            min: min,
            max: max,
            onChangeStart: disabled ? null : (_) => onStart(),
            onChanged: disabled ? null : onChanged,
            onChangeEnd: disabled ? null : (_) => onEnd(),
          ),
          if (disabled && disabledHint != null)
            Padding(
              padding: const EdgeInsets.only(left: Spacing.xs),
              child: Text(
                disabledHint!,
                style: theme.textTheme.bodySmall?.copyWith(
                  color:
                      theme.colorScheme.onSurface.withValues(alpha: 0.55),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
