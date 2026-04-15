import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../../../../core/logging/app_logger.dart';
import '../../../../engine/layers/content_layer.dart';

final _log = AppLogger('LayerHit');

/// Result of a hit test: the layer that was hit (top-most) and its
/// axis-aligned bounding rect in local canvas coords.
class LayerHit {
  const LayerHit({required this.layer, required this.bounds});

  final ContentLayer layer;

  /// Rect in the canvas' local coordinate space (same space the gesture
  /// detector delivers events in).
  final Rect bounds;
}

/// Hit-tests the given [layers] against a local tap position.
///
/// Iterates in reverse (top-most first) so the user interacts with the
/// visually-uppermost layer. Drawing layers are skipped — they have no
/// per-instance transform and aren't interactive in this phase.
/// Adjustment layers are also skipped; they cover the whole canvas.
LayerHit? hitTestLayers({
  required List<ContentLayer> layers,
  required Offset local,
  required Size canvasSize,
}) {
  for (var i = layers.length - 1; i >= 0; i--) {
    final layer = layers[i];
    if (!layer.visible) continue;
    final rect = boundsOfLayer(layer, canvasSize);
    if (rect == null) continue;
    if (rect.contains(local)) {
      _log.d('hit', {'id': layer.id, 'kind': layer.kind.name});
      return LayerHit(layer: layer, bounds: rect);
    }
  }
  return null;
}

/// Axis-aligned bounding rect of the given layer within [canvasSize].
/// Null means the layer isn't positionable (DrawingLayer, AdjustmentLayer).
///
/// For text / sticker layers we measure the text painter once to get
/// the intrinsic size, then multiply by [ContentLayer.scale] to get the
/// world-space extent. Rotation is ignored for hit-testing — we use the
/// rotation-enclosing AABB so a rotated sticker is still easy to tap.
Rect? boundsOfLayer(ContentLayer layer, Size canvasSize) {
  final TextPainter painter;
  if (layer is TextLayer) {
    TextStyle style = TextStyle(
      color: Color(layer.colorArgb),
      fontSize: layer.fontSize,
      fontWeight: layer.bold ? FontWeight.bold : FontWeight.normal,
      fontStyle: layer.italic ? FontStyle.italic : FontStyle.normal,
    );
    if (layer.fontFamily != null) {
      try {
        style = GoogleFonts.getFont(layer.fontFamily!, textStyle: style);
      } catch (_) {}
    }
    painter = TextPainter(
      text: TextSpan(text: layer.text, style: style),
      textDirection: TextDirection.ltr,
      textAlign: TextAlign.center,
    )..layout();
  } else if (layer is StickerLayer) {
    painter = TextPainter(
      text: TextSpan(
        text: layer.character,
        style: TextStyle(fontSize: layer.fontSize),
      ),
      textDirection: TextDirection.ltr,
      textAlign: TextAlign.center,
    )..layout();
  } else {
    return null;
  }
  // Scaled size.
  final w = painter.width * layer.scale;
  final h = painter.height * layer.scale;
  // Expand to enclosing AABB for the rotated rectangle so hit-testing
  // still works after a rotation.
  final cos = layer.rotation.abs() < 1e-4 ? 1.0 : math.cos(layer.rotation);
  final sin = layer.rotation.abs() < 1e-4 ? 0.0 : math.sin(layer.rotation);
  final aabbW = (w * cos.abs() + h * sin.abs()).toDouble();
  final aabbH = (w * sin.abs() + h * cos.abs()).toDouble();
  final cx = canvasSize.width * layer.x;
  final cy = canvasSize.height * layer.y;
  // Add a small touch target padding (~12 px) so users can still grab
  // small stickers.
  const pad = 12.0;
  return Rect.fromLTWH(
    cx - aabbW / 2 - pad,
    cy - aabbH / 2 - pad,
    aabbW + pad * 2,
    aabbH + pad * 2,
  );
}

/// CustomPainter that draws a dashed bounding box + corner anchors
/// around the selected layer. Purely visual; gestures are handled by
/// [SnapseedGestureLayer].
class LayerSelectionHandlesPainter extends CustomPainter {
  const LayerSelectionHandlesPainter({
    required this.bounds,
    required this.color,
  });

  final Rect bounds;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final stroke = Paint()
      ..color = color
      ..strokeWidth = 1.5
      ..style = PaintingStyle.stroke;
    // Dashed rectangle.
    const dashLen = 6.0;
    const gapLen = 4.0;
    final path = Path();
    void dashLine(Offset a, Offset b) {
      final dx = b.dx - a.dx;
      final dy = b.dy - a.dy;
      final dist = math.sqrt(dx * dx + dy * dy);
      if (dist < 1e-3) return;
      final ux = dx / dist;
      final uy = dy / dist;
      var traveled = 0.0;
      while (traveled < dist) {
        final segEnd = math.min(traveled + dashLen, dist);
        path.moveTo(a.dx + ux * traveled, a.dy + uy * traveled);
        path.lineTo(a.dx + ux * segEnd, a.dy + uy * segEnd);
        traveled = segEnd + gapLen;
      }
    }

    dashLine(bounds.topLeft, bounds.topRight);
    dashLine(bounds.topRight, bounds.bottomRight);
    dashLine(bounds.bottomRight, bounds.bottomLeft);
    dashLine(bounds.bottomLeft, bounds.topLeft);
    canvas.drawPath(path, stroke);

    // Corner anchors.
    final fill = Paint()..color = color;
    const r = 5.0;
    for (final c in [
      bounds.topLeft,
      bounds.topRight,
      bounds.bottomLeft,
      bounds.bottomRight,
    ]) {
      canvas.drawCircle(c, r, fill);
      canvas.drawCircle(c, r, Paint()
        ..color = Colors.white
        ..strokeWidth = 1.5
        ..style = PaintingStyle.stroke);
    }
  }

  @override
  bool shouldRepaint(covariant LayerSelectionHandlesPainter old) {
    return old.bounds != bounds || old.color != color;
  }
}
