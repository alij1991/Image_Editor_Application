import 'package:flutter/material.dart';

import '../../../../core/platform/haptics.dart';
import '../../../../engine/pipeline/edit_op_type.dart';
import '../../../../engine/pipeline/pipeline_extensions.dart';
import '../../../../engine/rendering/shader_pass.dart';
import '../notifiers/editor_session.dart';

/// On-canvas drag handle for the vignette centre. Renders only when
/// the user has authored a non-zero vignette amount; otherwise the
/// widget collapses to a zero-size box and gestures fall through to
/// the SnapseedGestureLayer below.
///
/// The handle sits at a 48 dp Positioned slot so the rest of the
/// canvas stays touchable — Flutter's Stack hit-tests topmost first
/// but only consumes the event when a child responds, and this widget
/// only places one child (the dot itself), leaving the rest empty.
class VignetteCenterOverlay extends StatelessWidget {
  const VignetteCenterOverlay({required this.session, super.key});

  final EditorSession session;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<List<ShaderPass>>(
      valueListenable: session.previewController.passes,
      builder: (context, _, _) {
        final vignette =
            session.committedPipeline.findOp(EditOpType.vignette);
        if (vignette == null) return const SizedBox.shrink();
        final amount =
            (vignette.parameters['amount'] as num?)?.toDouble() ?? 0;
        // Don't render the dot for an essentially-disabled vignette
        // — the handle only makes sense once the effect is visible.
        if (amount.abs() < 0.01) return const SizedBox.shrink();
        final centerX =
            (vignette.parameters['centerX'] as num?)?.toDouble() ?? 0.5;
        final centerY =
            (vignette.parameters['centerY'] as num?)?.toDouble() ?? 0.5;

        return LayoutBuilder(
          builder: (ctx, constraints) {
            final geom = session.previewController.geometry.value;
            final crop = geom.effectiveCropRect;
            final source = session.sourceImage;
            // Rotation may swap aspect; the displayed rect always
            // matches what ImageCanvas paints.
            final rotated = geom.rotationStepsNormalized.isOdd;
            final imgAspect = rotated
                ? (source.height * crop.height) /
                    (source.width * crop.width)
                : (source.width * crop.width) /
                    (source.height * crop.height);

            final cw = constraints.maxWidth;
            final ch = constraints.maxHeight;
            if (cw <= 0 || ch <= 0) return const SizedBox.shrink();
            final canvasAspect = cw / ch;
            late double imgW, imgH;
            if (imgAspect > canvasAspect) {
              imgW = cw;
              imgH = cw / imgAspect;
            } else {
              imgH = ch;
              imgW = ch * imgAspect;
            }
            final imgLeft = (cw - imgW) / 2;
            final imgTop = (ch - imgH) / 2;
            final dotX = imgLeft + centerX * imgW;
            final dotY = imgTop + centerY * imgH;

            return Stack(
              children: [
                Positioned(
                  left: dotX - 24,
                  top: dotY - 24,
                  width: 48,
                  height: 48,
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onPanStart: (_) => Haptics.tap(),
                    onPanUpdate: (d) {
                      // Re-read centre from the session each tick so
                      // the math is never based on a stale capture.
                      final v = session.committedPipeline
                          .findOp(EditOpType.vignette);
                      if (v == null) return;
                      final cx =
                          (v.parameters['centerX'] as num?)?.toDouble() ??
                              0.5;
                      final cy =
                          (v.parameters['centerY'] as num?)?.toDouble() ??
                              0.5;
                      session.setVignetteCenter(
                        cx + d.delta.dx / imgW,
                        cy + d.delta.dy / imgH,
                      );
                    },
                    child: const _CentreDot(),
                  ),
                ),
              ],
            );
          },
        );
      },
    );
  }
}

/// Visual: a hollow ring with a small filled core, white-over-shadow
/// so it stays legible against bright and dark image regions alike.
class _CentreDot extends StatelessWidget {
  const _CentreDot();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Container(
        width: 28,
        height: 28,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          border: Border.all(color: Colors.white, width: 2),
          boxShadow: const [
            BoxShadow(
              color: Color(0x99000000),
              blurRadius: 4,
              offset: Offset(0, 1),
            ),
          ],
        ),
        child: Center(
          child: Container(
            width: 8,
            height: 8,
            decoration: const BoxDecoration(
              shape: BoxShape.circle,
              color: Colors.white,
            ),
          ),
        ),
      ),
    );
  }
}
