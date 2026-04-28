import 'package:flutter/material.dart';

import '../../../../core/logging/app_logger.dart';
import '../../../../core/platform/haptics.dart';
import '../../../../core/theme/spacing.dart';
import '../../../../engine/geometry/guided_upright.dart';
import '../../../../engine/history/history_state.dart';
import '../../../../engine/pipeline/edit_op_type.dart';
import '../../../../engine/pipeline/pipeline_extensions.dart';
import '../notifiers/editor_session.dart';
import 'crop_overlay.dart';
import 'guided_upright_overlay.dart';
import 'slider_row.dart';

final _log = AppLogger('GeometryPanel');

/// Geometry category panel: 90° rotate, flip H/V, straighten slider, and
/// crop aspect-ratio chips. The perspective/keystone corner-handle UI
/// ships in a later phase.
class GeometryPanel extends StatelessWidget {
  const GeometryPanel({
    required this.session,
    required this.state,
    super.key,
  });

  final EditorSession session;
  final HistoryState state;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final pipeline = state.pipeline;
    final geom = pipeline.geometryState;

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(
            Spacing.lg,
            Spacing.sm,
            Spacing.lg,
            Spacing.xs,
          ),
          child: Text(
            'ROTATE & FLIP',
            style: theme.textTheme.labelSmall?.copyWith(
              color: theme.colorScheme.primary,
              letterSpacing: 1.2,
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: Spacing.lg,
            vertical: Spacing.sm,
          ),
          child: Wrap(
            spacing: Spacing.sm,
            runSpacing: Spacing.sm,
            children: [
              _IconLabelButton(
                icon: Icons.rotate_90_degrees_ccw,
                label: 'Left',
                tooltip: 'Rotate 90° counter-clockwise',
                onTap: () {
                  _log.i('rotate ccw tapped');
                  Haptics.tap();
                  session.rotate90(-1);
                },
              ),
              _IconLabelButton(
                icon: Icons.rotate_90_degrees_cw,
                label: 'Right',
                tooltip: 'Rotate 90° clockwise',
                onTap: () {
                  _log.i('rotate cw tapped');
                  Haptics.tap();
                  session.rotate90(1);
                },
              ),
              _IconLabelButton(
                icon: Icons.flip,
                label: 'Flip H',
                tooltip: 'Mirror horizontally',
                selected: geom.flipH,
                onTap: () {
                  _log.i('flip h tapped');
                  Haptics.tap();
                  session.toggleFlipH();
                },
              ),
              _IconLabelButton(
                icon: Icons.flip_camera_android,
                label: 'Flip V',
                tooltip: 'Mirror vertically',
                selected: geom.flipV,
                onTap: () {
                  _log.i('flip v tapped');
                  Haptics.tap();
                  session.toggleFlipV();
                },
              ),
              _IconLabelButton(
                icon: Icons.crop,
                label: 'Crop',
                tooltip: 'Open the crop overlay',
                selected: geom.hasCrop,
                onTap: () async {
                  _log.i('crop tapped');
                  Haptics.tap();
                  final result = await Navigator.of(context, rootNavigator: true)
                      .push<CropOverlayResult>(
                    MaterialPageRoute(
                      fullscreenDialog: true,
                      builder: (_) => CropOverlay(
                        source: session.sourceImage,
                        initial: geom.effectiveCropRect,
                        initialAspect: geom.cropAspectRatio,
                        onDone: (r) =>
                            Navigator.of(context).pop(r),
                        onCancel: () => Navigator.of(context).pop(),
                      ),
                    ),
                  );
                  if (result == null) return;
                  session.setCropRect(result.cropRect);
                  if (result.aspectRatio != geom.cropAspectRatio) {
                    session.setCropAspectRatio(result.aspectRatio);
                  }
                },
              ),
              // XVI.45 — Guided Upright. Opens a modal where the user
              // draws 2-4 line guides on edges that should be
              // horizontal or vertical. The pass builder solves for
              // the homography on every render.
              _IconLabelButton(
                icon: Icons.straighten,
                label: 'Upright',
                tooltip: 'Draw guide lines to fix perspective',
                selected: pipeline.findOp(EditOpType.guidedUpright) != null,
                onTap: () async {
                  _log.i('guided upright tapped');
                  Haptics.tap();
                  final initialOp =
                      pipeline.findOp(EditOpType.guidedUpright);
                  final initial = initialOp == null
                      ? const <GuidedUprightLine>[]
                      : GuidedUprightLineCodec.decode(
                          initialOp.parameters['lines'],
                        );
                  final result = await Navigator.of(
                    context,
                    rootNavigator: true,
                  ).push<List<GuidedUprightLine>>(
                    MaterialPageRoute(
                      fullscreenDialog: true,
                      builder: (_) => GuidedUprightOverlay(
                        source: session.sourceImage,
                        initial: initial,
                        onDone: (lines) =>
                            Navigator.of(context).pop(lines),
                        onCancel: () => Navigator.of(context).pop(),
                      ),
                    ),
                  );
                  if (result == null) return;
                  session.setGuidedUprightLines(result);
                },
              ),
            ],
          ),
        ),
        const SizedBox(height: Spacing.sm),
        // XVI.37 — Auto-straighten button. Lifts the scanner's
        // OpenCV Hough-line deskew into the editor. Silent fallback
        // when the estimator returns null (no lines, decode error,
        // OpenCV missing).
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: Spacing.lg),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              TextButton.icon(
                icon: const Icon(Icons.auto_fix_high, size: 18),
                label: const Text('Auto'),
                onPressed: () async {
                  Haptics.tap();
                  _log.i('autoStraighten tapped');
                  final angle = await session.autoStraighten();
                  if (!context.mounted) return;
                  final messenger = ScaffoldMessenger.maybeOf(context);
                  if (angle == null) {
                    messenger?.showSnackBar(const SnackBar(
                      content: Text('Could not detect a horizon'),
                      duration: Duration(seconds: 2),
                    ));
                  } else if (angle == 0) {
                    messenger?.showSnackBar(const SnackBar(
                      content: Text('Already level'),
                      duration: Duration(seconds: 2),
                    ));
                  }
                },
              ),
            ],
          ),
        ),
        SliderRow(
          key: ValueKey(
              'straighten-${geom.straightenDegrees.toStringAsFixed(3)}'),
          label: 'Straighten',
          description:
              'Fine rotation in degrees. Use to level the horizon after a tilt.',
          initialValue: geom.straightenDegrees,
          min: -45,
          max: 45,
          identity: 0,
          formatValue: (v) => '${v.toStringAsFixed(1)}°',
          onChanged: (v) {
            _log.d('straighten', {'value': v});
            session.setScalar(EditOpType.straighten, v);
          },
          onChangeEnd: (_) => session.flushPendingCommit(),
        ),
        const SizedBox(height: Spacing.sm),
        Padding(
          padding: const EdgeInsets.fromLTRB(
            Spacing.lg,
            Spacing.md,
            Spacing.lg,
            Spacing.xs,
          ),
          child: Row(
            children: [
              Text(
                'CROP ASPECT',
                style: theme.textTheme.labelSmall?.copyWith(
                  color: theme.colorScheme.primary,
                  letterSpacing: 1.2,
                ),
              ),
              const SizedBox(width: Spacing.xs),
              Tooltip(
                message: 'Locks the aspect ratio for the crop overlay. '
                    'Tap Crop above to drag the rect.',
                child: Icon(
                  Icons.help_outline,
                  size: 14,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
        _CropAspectRow(
          active: geom.cropAspectRatio,
          onSelect: (ratio) {
            _log.i('crop aspect selected', {'ratio': ratio});
            Haptics.tap();
            session.setCropAspectRatio(ratio);
          },
        ),
        // XVI.38 — Smart crop suggestions. Three taps apply a crop
        // centred on the largest cached face (FaceDetectionCache),
        // falling back to image-centre when no face has been detected
        // yet. The user can still drag handles afterwards via the
        // Crop button above.
        Padding(
          padding: const EdgeInsets.fromLTRB(
            Spacing.lg,
            Spacing.md,
            Spacing.lg,
            Spacing.xs,
          ),
          child: Row(
            children: [
              Text(
                'SMART CROP',
                style: theme.textTheme.labelSmall?.copyWith(
                  color: theme.colorScheme.primary,
                  letterSpacing: 1.2,
                ),
              ),
              const SizedBox(width: Spacing.xs),
              Tooltip(
                message: 'Tap an aspect to centre on the largest face '
                    '(or image centre as fallback). You can then drag '
                    'the crop handles to fine-tune.',
                child: Icon(
                  Icons.help_outline,
                  size: 14,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: Spacing.lg,
            vertical: Spacing.sm,
          ),
          child: Row(
            children: [
              _SmartCropChip(
                label: 'Square',
                aspect: 1.0,
                session: session,
              ),
              const SizedBox(width: Spacing.sm),
              _SmartCropChip(
                label: '4:5',
                aspect: 4 / 5,
                session: session,
              ),
              const SizedBox(width: Spacing.sm),
              _SmartCropChip(
                label: '16:9',
                aspect: 16 / 9,
                session: session,
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// XVI.38 — small chip widget that applies a smart crop on tap. Pure
/// view; the math + face lookup happens in
/// [EditorSession.applySmartCrop].
class _SmartCropChip extends StatelessWidget {
  const _SmartCropChip({
    required this.label,
    required this.aspect,
    required this.session,
  });

  final String label;
  final double aspect;
  final EditorSession session;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ActionChip(
      label: Text(label),
      avatar: const Icon(Icons.auto_fix_high, size: 16),
      backgroundColor: theme.colorScheme.surfaceContainerHigh,
      onPressed: () {
        _log.i('smart crop tapped', {'aspect': aspect});
        Haptics.tap();
        final applied = session.applySmartCrop(aspect);
        if (applied == null) {
          final messenger = ScaffoldMessenger.maybeOf(context);
          messenger?.showSnackBar(const SnackBar(
            content: Text('Image is too small to crop'),
            duration: Duration(seconds: 2),
          ));
        }
      },
    );
  }
}

/// One of the "Rotate Left / Right / Flip H / Flip V" buttons.
class _IconLabelButton extends StatelessWidget {
  const _IconLabelButton({
    required this.icon,
    required this.label,
    required this.tooltip,
    required this.onTap,
    this.selected = false,
  });

  final IconData icon;
  final String label;
  final String tooltip;
  final VoidCallback onTap;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final bg = selected
        ? theme.colorScheme.primary
        : theme.colorScheme.surfaceContainerHighest;
    final fg = selected
        ? theme.colorScheme.onPrimary
        : theme.colorScheme.onSurfaceVariant;
    return Tooltip(
      message: tooltip,
      child: Material(
        color: bg,
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(12),
          child: Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: Spacing.md,
              vertical: Spacing.sm,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(icon, size: 20, color: fg),
                const SizedBox(height: Spacing.xxs),
                Text(
                  label,
                  style: theme.textTheme.labelSmall?.copyWith(color: fg),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Crop aspect-ratio preset chips.
class _CropAspectRow extends StatelessWidget {
  const _CropAspectRow({required this.active, required this.onSelect});

  final double? active;
  final ValueChanged<double?> onSelect;

  static const List<_CropPreset> _presets = [
    _CropPreset(label: 'Free', ratio: null),
    _CropPreset(label: '1:1', ratio: 1.0),
    _CropPreset(label: '4:3', ratio: 4 / 3),
    _CropPreset(label: '3:4', ratio: 3 / 4),
    _CropPreset(label: '16:9', ratio: 16 / 9),
    _CropPreset(label: '9:16', ratio: 9 / 16),
    _CropPreset(label: '3:2', ratio: 3 / 2),
    _CropPreset(label: '2:3', ratio: 2 / 3),
  ];

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.symmetric(
        horizontal: Spacing.lg,
        vertical: Spacing.sm,
      ),
      child: Row(
        children: [
          for (final preset in _presets) ...[
            _AspectChip(
              label: preset.label,
              selected: _isSelected(preset.ratio, active),
              onTap: () => onSelect(preset.ratio),
            ),
            const SizedBox(width: Spacing.sm),
          ],
        ],
      ),
    );
  }

  bool _isSelected(double? presetRatio, double? active) {
    if (presetRatio == null) return active == null;
    if (active == null) return false;
    return (presetRatio - active).abs() < 1e-4;
  }
}

class _CropPreset {
  const _CropPreset({required this.label, required this.ratio});
  final String label;
  final double? ratio;
}

class _AspectChip extends StatelessWidget {
  const _AspectChip({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return ChoiceChip(
      label: Text(label),
      selected: selected,
      onSelected: (_) => onTap(),
    );
  }
}
