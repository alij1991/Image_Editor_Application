import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';

import 'shader_pass.dart';
import 'shader_renderer.dart';

/// A [RenderBox] that hosts the image canvas without ever calling
/// [markNeedsLayout] on uniform changes.
///
/// Per the blueprint:
/// > Key advantage: call `markNeedsPaint()` without `markNeedsLayout()`
/// > for efficient repaint when only filter parameters change.
///
/// The box's layout depends only on constraints; its paint depends on
/// the source image + the shader pass list. When slider values change
/// the owning widget updates the pass list and calls [updatePasses],
/// which calls `markNeedsPaint` (not layout).
class ImageCanvasRenderBox extends RenderBox {
  ImageCanvasRenderBox({
    required ui.Image source,
    List<ShaderPass> passes = const [],
    BoxFit fit = BoxFit.contain,
  })  : _source = source,
        _passes = passes,
        _fit = fit;

  ui.Image _source;
  List<ShaderPass> _passes;
  BoxFit _fit;

  ui.Image get source => _source;
  set source(ui.Image value) {
    if (identical(value, _source)) return;
    _source = value;
    markNeedsLayout(); // aspect ratio may have changed
  }

  List<ShaderPass> get passes => _passes;
  set passes(List<ShaderPass> value) {
    _passes = value;
    markNeedsPaint();
  }

  BoxFit get fit => _fit;
  set fit(BoxFit value) {
    if (_fit == value) return;
    _fit = value;
    markNeedsPaint();
  }

  /// Update only the shader passes (common case during slider drag).
  /// Never triggers layout.
  void updatePasses(List<ShaderPass> value) {
    _passes = value;
    markNeedsPaint();
  }

  @override
  bool get sizedByParent => false;

  @override
  void performLayout() {
    final imgAspect = _source.width / _source.height;
    Size target;
    if (constraints.hasBoundedWidth && constraints.hasBoundedHeight) {
      switch (_fit) {
        case BoxFit.contain:
          if (constraints.maxWidth / constraints.maxHeight > imgAspect) {
            target = Size(
              constraints.maxHeight * imgAspect,
              constraints.maxHeight,
            );
          } else {
            target = Size(
              constraints.maxWidth,
              constraints.maxWidth / imgAspect,
            );
          }
          break;
        case BoxFit.cover:
          if (constraints.maxWidth / constraints.maxHeight < imgAspect) {
            target = Size(
              constraints.maxHeight * imgAspect,
              constraints.maxHeight,
            );
          } else {
            target = Size(
              constraints.maxWidth,
              constraints.maxWidth / imgAspect,
            );
          }
          break;
        default:
          target = Size(constraints.maxWidth, constraints.maxHeight);
      }
    } else {
      target = constraints.constrain(
        Size(_source.width.toDouble(), _source.height.toDouble()),
      );
    }
    size = target;
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    final canvas = context.canvas;
    canvas.save();
    canvas.translate(offset.dx, offset.dy);
    // Delegate to ShaderRenderer for the actual pass chain. We construct
    // it transiently — the expensive thing (FragmentProgram) lives in the
    // shared registry, not in the renderer instance.
    final painter = ShaderRenderer(source: _source, passes: _passes);
    painter.paint(canvas, size);
    canvas.restore();
  }
}
