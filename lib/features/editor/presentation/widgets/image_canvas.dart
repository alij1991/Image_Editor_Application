import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../../../core/logging/app_logger.dart';
import '../../../../engine/layers/content_layer.dart';
import '../../../../engine/pipeline/geometry_state.dart';
import '../../../../engine/rendering/shader_pass.dart';
import '../../../../engine/rendering/shader_renderer.dart';
import 'layer_painter.dart';

final _log = AppLogger('ImageCanvas');

/// Renders [source] through the current shader pass list and overlays
/// content layers on top, with geometry transforms composed around
/// everything.
///
/// Layer hierarchy:
///
/// - `RepaintBoundary`
/// - `ValueListenableBuilder` of `GeometryState` (rebuilds on geom change)
/// - `RotatedBox(quarterTurns)` (handles 90° aspect swap)
/// - `AspectRatio(srcAspect)`
/// - `Transform.rotate(straightenRadians)`
/// - `Transform.scale(flipH, flipV)`
/// - `ValueListenableBuilder` of `List[ShaderPass]` (rebuilds on pass change)
/// - `ValueListenableBuilder` of `List[ContentLayer]` (rebuilds on layer change)
/// - `CustomPaint(painter: ShaderRenderer, foregroundPainter: LayerPainter)`
class ImageCanvas extends StatelessWidget {
  const ImageCanvas({
    required this.source,
    required this.passes,
    required this.geometry,
    required this.layers,
    super.key,
  });

  final ui.Image source;
  final ValueListenable<List<ShaderPass>> passes;
  final ValueListenable<GeometryState> geometry;
  final ValueListenable<List<ContentLayer>> layers;

  @override
  Widget build(BuildContext context) {
    _log.d('build', {
      'width': source.width,
      'height': source.height,
    });
    return RepaintBoundary(
      child: ValueListenableBuilder<GeometryState>(
        valueListenable: geometry,
        builder: (context, geom, _) {
          _log.d('rebuild geometry', {'state': geom.toString()});
          return Center(
            child: RotatedBox(
              quarterTurns: geom.rotationStepsNormalized,
              child: AspectRatio(
                aspectRatio: source.width / source.height,
                child: ClipRect(
                  child: Transform.rotate(
                    angle: geom.straightenRadians,
                    child: Transform.scale(
                      scaleX: geom.flipH ? -1.0 : 1.0,
                      scaleY: geom.flipV ? -1.0 : 1.0,
                      child: ValueListenableBuilder<List<ShaderPass>>(
                        valueListenable: passes,
                        builder: (context, currentPasses, _) {
                          _log.d('rebuild passes',
                              {'count': currentPasses.length});
                          return ValueListenableBuilder<List<ContentLayer>>(
                            valueListenable: layers,
                            builder: (context, currentLayers, _) {
                              _log.d('rebuild layers',
                                  {'count': currentLayers.length});
                              return CustomPaint(
                                painter: ShaderRenderer(
                                  source: source,
                                  passes: currentPasses,
                                ),
                                foregroundPainter:
                                    LayerPainter(layers: currentLayers),
                                size: Size.infinite,
                              );
                            },
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
