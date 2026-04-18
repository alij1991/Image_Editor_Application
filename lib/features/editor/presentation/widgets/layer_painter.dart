import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../../../../engine/layers/content_layer.dart';
import '../../../../engine/layers/layer_blend_mode.dart';
import '../../../../engine/layers/layer_mask.dart';

/// Foreground CustomPainter that draws [ContentLayer]s above the shader
/// chain. Consumed by [ImageCanvas] via `CustomPaint.foregroundPainter`
/// so text, stickers, and drawings compose on top of the edited image
/// without interfering with the shader-based color chain beneath.
///
/// Per-layer compositing rules:
///
///   - `visible == false` → skip entirely.
///   - `blendMode != normal` → draw into a `saveLayer` whose Paint uses
///     the mapped Flutter [BlendMode].
///   - `opacity < 1`        → same `saveLayer` also has its Paint color
///     alpha set to the opacity.
///   - `mask.shape != none` → after painting the layer content, apply a
///     gradient with [BlendMode.dstIn] so only the masked region
///     remains opaque.
class LayerPainter extends CustomPainter {
  LayerPainter({
    required this.layers,
    super.repaint,
  });

  final List<ContentLayer> layers;

  @override
  void paint(ui.Canvas canvas, ui.Size size) {
    for (final layer in layers) {
      if (!layer.visible) continue;
      final needsLayer = layer.opacity < 0.999 ||
          layer.blendMode != LayerBlendMode.normal ||
          !layer.mask.isIdentity;

      if (needsLayer) {
        final layerPaint = Paint()
          ..blendMode = layer.blendMode.flutter
          ..color = Colors.white.withValues(alpha: layer.opacity);
        canvas.saveLayer(Offset.zero & size, layerPaint);
      }

      _paintLayerContent(canvas, size, layer);

      if (!layer.mask.isIdentity) {
        _applyGradientMask(canvas, size, layer.mask);
      }

      if (needsLayer) {
        canvas.restore();
      }
    }
  }

  void _paintLayerContent(ui.Canvas canvas, ui.Size size, ContentLayer layer) {
    switch (layer) {
      case TextLayer():
        _paintText(canvas, size, layer);
        break;
      case StickerLayer():
        _paintSticker(canvas, size, layer);
        break;
      case DrawingLayer():
        _paintDrawing(canvas, size, layer);
        break;
      case AdjustmentLayer():
        _paintAdjustment(canvas, size, layer);
        break;
    }
  }

  /// Paint an [AdjustmentLayer]. Phase 9b only renders the
  /// background-removal variant: the layer's volatile
  /// [AdjustmentLayer.cutoutImage] (an RGBA image with the
  /// background already alpha-punched by the segmentation model) is
  /// stretched to cover the canvas.
  ///
  /// Null images are skipped so session reloads from persisted
  /// pipelines don't crash; they just render as if the layer is
  /// invisible until Phase 12 adds MementoStore persistence.
  void _paintAdjustment(
    ui.Canvas canvas,
    ui.Size size,
    AdjustmentLayer layer,
  ) {
    final image = layer.cutoutImage;
    if (image == null) return;
    final srcRect = ui.Rect.fromLTWH(
      0,
      0,
      image.width.toDouble(),
      image.height.toDouble(),
    );
    final dstRect = ui.Rect.fromLTWH(0, 0, size.width, size.height);
    canvas.drawImageRect(
      image,
      srcRect,
      dstRect,
      Paint()..filterQuality = ui.FilterQuality.medium,
    );
  }

  /// Apply a procedural gradient as an alpha mask using `dstIn`.
  ///
  /// The layer has already been drawn into the current saveLayer
  /// buffer; `dstIn` keeps only the destination pixels wherever the
  /// gradient alpha is non-zero.
  void _applyGradientMask(ui.Canvas canvas, ui.Size size, LayerMask mask) {
    final rect = Offset.zero & size;
    final paint = Paint()..blendMode = BlendMode.dstIn;
    const visibleColor = Color(0xFFFFFFFF);
    const hiddenColor = Color(0x00FFFFFF);
    final feather = mask.feather.clamp(0.0, 1.0);

    switch (mask.shape) {
      case MaskShape.none:
        return;
      case MaskShape.linear:
        final endpoints = mask.linearEndpoints();
        final begin =
            Offset(endpoints.$1.x * size.width, endpoints.$1.y * size.height);
        final end =
            Offset(endpoints.$2.x * size.width, endpoints.$2.y * size.height);
        final colors = mask.inverted
            ? [visibleColor, hiddenColor]
            : [hiddenColor, visibleColor];
        // feather = 0 → hard edge at the midpoint (stops collapse to 0.5)
        // feather = 1 → full gradient spanning [0, 1]
        final halfBand = 0.5 * feather;
        final stopsList = [
          (0.5 - halfBand).clamp(0.0, 0.5),
          (0.5 + halfBand).clamp(0.5, 1.0),
        ];
        paint.shader = ui.Gradient.linear(
          begin,
          end,
          colors,
          stopsList,
        );
        canvas.drawRect(rect, paint);
        return;
      case MaskShape.radial:
        final shorterDim = math.min(size.width, size.height);
        final inner = mask.innerRadius.clamp(0.0, 1.0) * shorterDim;
        final outer = mask.outerRadius.clamp(0.0, 1.0) * shorterDim;
        final innerClamped = math.min(inner, math.max(outer - 1, 1.0));
        final spread = math.max(outer - innerClamped, 1.0);
        final center = Offset(mask.cx * size.width, mask.cy * size.height);
        final colors = mask.inverted
            ? [hiddenColor, hiddenColor, visibleColor]
            : [visibleColor, visibleColor, hiddenColor];
        final innerStop =
            (innerClamped / (innerClamped + spread)).clamp(0.0, 0.99);
        paint.shader = ui.Gradient.radial(
          center,
          math.max(outer, 1.0),
          colors,
          [0.0, innerStop, 1.0],
        );
        canvas.drawRect(rect, paint);
        return;
    }
  }

  void _paintText(ui.Canvas canvas, ui.Size size, TextLayer layer) {
    final shadows = layer.shadow.enabled
        ? [
            ui.Shadow(
              color: Color(
                layer.shadow.colorArgb ?? TextShadow.kAutoColorArgb,
              ),
              offset: Offset(layer.shadow.dx, layer.shadow.dy),
              blurRadius: layer.shadow.blur,
            ),
          ]
        : null;
    TextStyle style = TextStyle(
      color: Color(layer.colorArgb),
      fontSize: layer.fontSize,
      fontWeight: layer.bold ? FontWeight.bold : FontWeight.normal,
      fontStyle: layer.italic ? FontStyle.italic : FontStyle.normal,
      shadows: shadows,
    );
    if (layer.fontFamily != null) {
      try {
        style = GoogleFonts.getFont(layer.fontFamily!, textStyle: style);
      } catch (_) {}
    }
    final flutterAlign = switch (layer.alignment) {
      TextAlignment.left => TextAlign.left,
      TextAlignment.center => TextAlign.center,
      TextAlignment.right => TextAlign.right,
    };
    final painter = TextPainter(
      text: TextSpan(text: layer.text, style: style),
      textDirection: TextDirection.ltr,
      textAlign: flutterAlign,
    )..layout();

    final center = Offset(size.width * layer.x, size.height * layer.y);
    canvas.save();
    canvas.translate(center.dx, center.dy);
    canvas.rotate(layer.rotation);
    canvas.scale(layer.scale);
    painter.paint(canvas, Offset(-painter.width / 2, -painter.height / 2));
    canvas.restore();
  }

  void _paintSticker(ui.Canvas canvas, ui.Size size, StickerLayer layer) {
    final painter = TextPainter(
      text: TextSpan(
        text: layer.character,
        style: TextStyle(fontSize: layer.fontSize),
      ),
      textDirection: TextDirection.ltr,
      textAlign: TextAlign.center,
    )..layout();

    final center = Offset(size.width * layer.x, size.height * layer.y);
    canvas.save();
    canvas.translate(center.dx, center.dy);
    canvas.rotate(layer.rotation);
    canvas.scale(layer.scale);
    painter.paint(canvas, Offset(-painter.width / 2, -painter.height / 2));
    canvas.restore();
  }

  void _paintDrawing(ui.Canvas canvas, ui.Size size, DrawingLayer layer) {
    for (final stroke in layer.strokes) {
      _paintOneStroke(canvas, size, stroke);
    }
  }

  void _paintOneStroke(
    ui.Canvas canvas,
    ui.Size size,
    DrawingStroke stroke,
  ) {
    final base = Color(stroke.colorArgb);
    // Per-stroke opacity multiplies the colour's alpha so a fully
    // opaque colour can still be laid down translucently.
    final color = base.withValues(
      alpha: ((base.a) * stroke.opacity).clamp(0.0, 1.0),
    );

    // Spray brushes paint scattered dots along the path instead of a
    // continuous line — handled separately because the per-pixel
    // shape diverges from the pen/marker drawPath path.
    if (stroke.brushType == DrawingBrushType.spray) {
      _paintSpray(canvas, size, stroke, color);
      return;
    }

    if (stroke.points.length < 2) {
      if (stroke.points.length == 1) {
        final p = stroke.points.first;
        canvas.drawCircle(
          Offset(p.x * size.width, p.y * size.height),
          stroke.width / 2,
          Paint()..color = color,
        );
      }
      return;
    }
    final path = Path();
    final first = stroke.points.first;
    path.moveTo(first.x * size.width, first.y * size.height);
    for (int i = 1; i < stroke.points.length; i++) {
      final p = stroke.points[i];
      path.lineTo(p.x * size.width, p.y * size.height);
    }
    // Marker = wider, naturally-translucent stroke. We bump the
    // width by 1.6× and the colour alpha is already user-set
    // through opacity.
    final widthMul =
        stroke.brushType == DrawingBrushType.marker ? 1.6 : 1.0;
    final paint = Paint()
      ..color = color
      ..strokeWidth = stroke.width * widthMul
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..style = PaintingStyle.stroke
      ..isAntiAlias = true;
    // Hardness < 1 → soft falloff. Convert to a Gaussian blur
    // proportional to the stroke width so the effect scales with
    // brush size. hardness = 1 → no blur (cheap fast path).
    final softness = (1.0 - stroke.hardness).clamp(0.0, 1.0);
    if (softness > 0.01) {
      paint.maskFilter = ui.MaskFilter.blur(
        ui.BlurStyle.normal,
        softness * stroke.width * 0.5,
      );
    }
    canvas.drawPath(path, paint);
  }

  /// Paint a "spray" stroke: scattered dots along the path with
  /// jitter proportional to stroke width. Density is constant so a
  /// long flick deposits more paint than a tap.
  void _paintSpray(
    ui.Canvas canvas,
    ui.Size size,
    DrawingStroke stroke,
    Color color,
  ) {
    final paint = Paint()..color = color;
    final radius = stroke.width * 0.5;
    final rng = math.Random(stroke.points.length); // deterministic
    const dotsPerSegment = 12;
    final pts = stroke.points;
    if (pts.length == 1) {
      final p = pts.first;
      _spraySplat(
        canvas,
        Offset(p.x * size.width, p.y * size.height),
        radius,
        paint,
        rng,
      );
      return;
    }
    for (int i = 1; i < pts.length; i++) {
      final a = pts[i - 1];
      final b = pts[i];
      final ax = a.x * size.width;
      final ay = a.y * size.height;
      final bx = b.x * size.width;
      final by = b.y * size.height;
      for (int d = 0; d < dotsPerSegment; d++) {
        final t = d / dotsPerSegment;
        final x = ax + (bx - ax) * t;
        final y = ay + (by - ay) * t;
        _spraySplat(canvas, Offset(x, y), radius, paint, rng);
      }
    }
  }

  void _spraySplat(
    ui.Canvas canvas,
    Offset center,
    double radius,
    Paint paint,
    math.Random rng,
  ) {
    const splats = 8;
    for (int i = 0; i < splats; i++) {
      final angle = rng.nextDouble() * math.pi * 2;
      final dist = math.sqrt(rng.nextDouble()) * radius;
      final dx = math.cos(angle) * dist;
      final dy = math.sin(angle) * dist;
      canvas.drawCircle(
        center + Offset(dx, dy),
        0.6 + rng.nextDouble() * 0.6,
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(covariant LayerPainter oldDelegate) {
    if (oldDelegate.layers.length != layers.length) return true;
    for (int i = 0; i < layers.length; i++) {
      if (!identical(oldDelegate.layers[i], layers[i])) return true;
    }
    return false;
  }
}
