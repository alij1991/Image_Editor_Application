import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../../../core/logging/app_logger.dart';
import '../../../../core/platform/haptics.dart';
import '../../../../engine/pipeline/geometry_state.dart';
import '../../../../engine/rendering/shader_pass.dart';
import '../../../../engine/rendering/shader_renderer.dart';
import '../../../../engine/rendering/shaders/effect_shaders.dart';

final _log = AppLogger('BeforeAfterSplit');

/// Draggable split-view comparison using `before_after_wipe.frag`.
///
/// Renders the edited pipeline on one side of a draggable split line and
/// the original image on the other. The split position is held by a
/// [ValueNotifier] so dragging the handle never rebuilds any widget above
/// the [CustomPaint]. Geometry transforms are applied by wrapping the
/// Stack in RotatedBox + Transform so the split stays aligned with the
/// rotated image.
class BeforeAfterSplit extends StatefulWidget {
  const BeforeAfterSplit({
    required this.source,
    required this.editedPasses,
    required this.geometry,
    super.key,
  });

  final ui.Image source;
  final ValueListenable<List<ShaderPass>> editedPasses;
  final ValueListenable<GeometryState> geometry;

  @override
  State<BeforeAfterSplit> createState() => _BeforeAfterSplitState();
}

class _BeforeAfterSplitState extends State<BeforeAfterSplit> {
  final ValueNotifier<double> _splitPos = ValueNotifier(0.5);

  @override
  void initState() {
    super.initState();
    _log.i('mounted');
  }

  @override
  void dispose() {
    _log.i('unmounted');
    _splitPos.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      child: ValueListenableBuilder<GeometryState>(
        valueListenable: widget.geometry,
        builder: (context, geom, _) {
          return Center(
            child: RotatedBox(
              quarterTurns: geom.rotationStepsNormalized,
              child: AspectRatio(
                aspectRatio: widget.source.width / widget.source.height,
                child: ClipRect(
                  child: Transform.rotate(
                    angle: geom.straightenRadians,
                    child: Transform.scale(
                      scaleX: geom.flipH ? -1.0 : 1.0,
                      scaleY: geom.flipV ? -1.0 : 1.0,
                      child: LayoutBuilder(
                        builder: (context, constraints) {
                          return GestureDetector(
                            behavior: HitTestBehavior.opaque,
                            onHorizontalDragStart: (_) {
                              _log.d('drag start', {'from': _splitPos.value});
                            },
                            onHorizontalDragUpdate: (details) {
                              final next = (_splitPos.value +
                                      details.delta.dx /
                                          constraints.maxWidth)
                                  .clamp(0.0, 1.0);
                              _splitPos.value = next;
                            },
                            onHorizontalDragEnd: (_) {
                              _log.d('drag end', {'final': _splitPos.value});
                              Haptics.tap();
                            },
                            child: Stack(
                              fit: StackFit.expand,
                              children: [
                                ValueListenableBuilder<List<ShaderPass>>(
                                  valueListenable: widget.editedPasses,
                                  builder: (context, passes, _) {
                                    return ValueListenableBuilder<double>(
                                      valueListenable: _splitPos,
                                      builder: (context, pos, _) {
                                        return CustomPaint(
                                          painter: _SplitPainter(
                                            source: widget.source,
                                            passes: passes,
                                            splitPos: pos,
                                          ),
                                          size: Size.infinite,
                                        );
                                      },
                                    );
                                  },
                                ),
                                ValueListenableBuilder<double>(
                                  valueListenable: _splitPos,
                                  builder: (context, pos, _) {
                                    return Align(
                                      alignment: Alignment(2 * pos - 1, 0),
                                      child: Container(
                                        width: 2,
                                        color: Colors.white70,
                                      ),
                                    );
                                  },
                                ),
                              ],
                            ),
                          );
                        },
                      ),
                    ),
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

class _SplitPainter extends CustomPainter {
  _SplitPainter({
    required this.source,
    required this.passes,
    required this.splitPos,
  });

  final ui.Image source;
  final List<ShaderPass> passes;
  final double splitPos;

  @override
  void paint(ui.Canvas canvas, ui.Size size) {
    final recorder = ui.PictureRecorder();
    final offCanvas = ui.Canvas(recorder);
    final editedPainter = ShaderRenderer(source: source, passes: passes);
    editedPainter.paint(offCanvas, size);
    final edited = recorder
        .endRecording()
        .toImageSync(size.width.round(), size.height.round());

    final wipePass = BeforeAfterWipeShader(
      original: source,
      splitPos: splitPos,
    ).toPass();
    final wipeRenderer = ShaderRenderer(
      source: edited,
      passes: [wipePass],
    );
    wipeRenderer.paint(canvas, size);
    edited.dispose();
  }

  @override
  bool shouldRepaint(covariant _SplitPainter oldDelegate) {
    return oldDelegate.source != source ||
        oldDelegate.passes != passes ||
        oldDelegate.splitPos != splitPos;
  }
}
