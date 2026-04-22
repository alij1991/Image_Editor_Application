import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../../../core/logging/app_logger.dart';
import '../../../../engine/layers/content_layer.dart';
import '../../../../engine/pipeline/geometry_state.dart';
import '../../../../engine/rendering/shader_pass.dart';
import '../../../../engine/rendering/shader_renderer.dart';
import '../../../../engine/rendering/shader_texture_pool.dart';
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
    this.texturePool,
    super.key,
  });

  final ui.Image source;
  final ValueListenable<List<ShaderPass>> passes;
  final ValueListenable<GeometryState> geometry;
  final ValueListenable<List<ContentLayer>> layers;

  /// Phase VI.1: ping-pong pool supplied by the session for intermediate
  /// shader-pass textures. Null in tests / callers without a session.
  final ShaderTexturePool? texturePool;

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
          final crop = geom.effectiveCropRect;
          // Show the cropped aspect ratio so the canvas always fills
          // the visible area without letterboxing. When the user
          // hasn't cropped (crop.isFull), this collapses to the
          // source's native aspect.
          final cropAspect = (source.width * crop.width) /
              (source.height * crop.height);
          final shaderTree = ValueListenableBuilder<List<ShaderPass>>(
            valueListenable: passes,
            builder: (context, currentPasses, _) {
              _log.d('rebuild passes', {'count': currentPasses.length});
              return ValueListenableBuilder<List<ContentLayer>>(
                valueListenable: layers,
                builder: (context, currentLayers, _) {
                  _log.d('rebuild layers',
                      {'count': currentLayers.length});
                  return CustomPaint(
                    painter: ShaderRenderer(
                      source: source,
                      passes: currentPasses,
                      pool: texturePool,
                    ),
                    foregroundPainter:
                        LayerPainter(layers: currentLayers),
                    size: Size.infinite,
                  );
                },
              );
            },
          );
          return Center(
            child: RotatedBox(
              quarterTurns: geom.rotationStepsNormalized,
              child: AspectRatio(
                aspectRatio: cropAspect,
                child: ClipRect(
                  child: LayoutBuilder(
                    builder: (context, constraints) {
                      final w = constraints.maxWidth;
                      final h = constraints.maxHeight;
                      // Position the source so the crop region fills
                      // the AspectRatio box: scale up by 1/cropW,
                      // 1/cropH, then translate so the crop's top-
                      // left aligns with (0, 0). When crop is full
                      // both factors are 1 and the offset is zero —
                      // the no-crop path is mathematically identical
                      // to the pre-crop layout.
                      final scaleX = 1.0 / crop.width;
                      final scaleY = 1.0 / crop.height;
                      return Transform.translate(
                        offset: Offset(
                          -crop.left * w * scaleX,
                          -crop.top * h * scaleY,
                        ),
                        child: SizedBox(
                          width: w * scaleX,
                          height: h * scaleY,
                          child: Transform.rotate(
                            angle: geom.straightenRadians,
                            child: Transform.scale(
                              scaleX: geom.flipH ? -1.0 : 1.0,
                              scaleY: geom.flipV ? -1.0 : 1.0,
                              child: shaderTree,
                            ),
                          ),
                        ),
                      );
                    },
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
