import 'package:flutter_test/flutter_test.dart';

import 'package:image_editor/engine/layers/content_layer.dart';
import 'package:image_editor/engine/pipeline/edit_op_type.dart';
import 'package:image_editor/engine/pipeline/edit_operation.dart';
import 'package:image_editor/engine/pipeline/edit_pipeline.dart';
import 'package:image_editor/engine/pipeline/pipeline_extensions.dart';

void main() {
  group('ContentLayer parsing', () {
    test('TextLayer round-trips through EditOperation params', () {
      const source = TextLayer(
        id: 'id-1',
        text: 'Hello',
        fontSize: 48,
        colorArgb: 0xFFFF0000,
        fontFamily: 'Roboto',
        bold: true,
        italic: false,
        opacity: 0.8,
        x: 0.3,
        y: 0.7,
        rotation: 0.5,
        scale: 1.2,
      );
      final op = EditOperation.create(
        type: EditOpType.text,
        parameters: source.toParams(),
      );
      final opWithId = op.copyWith(id: 'id-1');
      final parsed = TextLayer.fromOp(opWithId);
      expect(parsed.id, 'id-1');
      expect(parsed.text, 'Hello');
      expect(parsed.fontSize, 48);
      expect(parsed.colorArgb, 0xFFFF0000);
      expect(parsed.fontFamily, 'Roboto');
      expect(parsed.bold, true);
      expect(parsed.italic, false);
      expect(parsed.opacity, 0.8);
      expect(parsed.x, 0.3);
      expect(parsed.y, 0.7);
      expect(parsed.rotation, 0.5);
      expect(parsed.scale, 1.2);
    });

    test('StickerLayer round-trip', () {
      const sticker = StickerLayer(
        id: 'id-2',
        character: '🎉',
        fontSize: 96,
        x: 0.25,
        y: 0.75,
        rotation: 1.2,
        scale: 0.9,
      );
      final op = EditOperation.create(
        type: EditOpType.sticker,
        parameters: sticker.toParams(),
      ).copyWith(id: 'id-2');
      final parsed = StickerLayer.fromOp(op);
      expect(parsed.character, '🎉');
      expect(parsed.fontSize, 96);
      expect(parsed.x, 0.25);
      expect(parsed.rotation, 1.2);
      expect(parsed.scale, 0.9);
    });

    test('DrawingLayer round-trip with multiple strokes', () {
      const layer = DrawingLayer(
        id: 'id-3',
        strokes: [
          DrawingStroke(
            points: [StrokePoint(0.1, 0.2), StrokePoint(0.3, 0.4)],
            colorArgb: 0xFF00FF00,
            width: 4.0,
          ),
          DrawingStroke(
            points: [StrokePoint(0.5, 0.5)],
            colorArgb: 0xFF0000FF,
            width: 8.0,
          ),
        ],
        opacity: 0.9,
      );
      final op = EditOperation.create(
        type: EditOpType.drawing,
        parameters: layer.toParams(),
      ).copyWith(id: 'id-3');
      final parsed = DrawingLayer.fromOp(op);
      expect(parsed.strokes.length, 2);
      expect(parsed.strokes[0].points.length, 2);
      expect(parsed.strokes[0].colorArgb, 0xFF00FF00);
      expect(parsed.strokes[0].width, 4.0);
      expect(parsed.strokes[0].points[0].x, closeTo(0.1, 1e-9));
      expect(parsed.strokes[0].points[1].y, closeTo(0.4, 1e-9));
      expect(parsed.strokes[1].points.length, 1);
      expect(parsed.opacity, 0.9);
    });

    test('disabled op becomes invisible layer', () {
      var op = EditOperation.create(
        type: EditOpType.text,
        parameters: const {'text': 'Hi', 'fontSize': 32, 'colorArgb': 0xFFFFFFFF},
      );
      op = op.copyWith(enabled: false);
      final layer = TextLayer.fromOp(op);
      expect(layer.visible, false);
    });
  });

  group('PipelineReaders.contentLayers', () {
    test('empty pipeline returns empty layer list', () {
      final p = EditPipeline.forOriginal('/tmp/img.jpg');
      expect(p.contentLayers, isEmpty);
    });

    test('only layer ops are returned (color ops ignored)', () {
      final p = EditPipeline.forOriginal('/tmp/img.jpg')
          .append(EditOperation.create(
            type: EditOpType.brightness,
            parameters: {'value': 0.3},
          ))
          .append(EditOperation.create(
            type: EditOpType.text,
            parameters: {
              'text': 'Hi',
              'fontSize': 48.0,
              'colorArgb': 0xFFFFFFFF,
            },
          ))
          .append(EditOperation.create(
            type: EditOpType.sticker,
            parameters: {
              'character': '⭐',
              'fontSize': 80.0,
            },
          ));
      final layers = p.contentLayers;
      expect(layers.length, 2);
      expect(layers[0] is TextLayer, true);
      expect(layers[1] is StickerLayer, true);
    });

    test('order follows pipeline insertion order (paint order)', () {
      final p = EditPipeline.forOriginal('/tmp/img.jpg')
          .append(EditOperation.create(
            type: EditOpType.text,
            parameters: {
              'text': 'Background',
              'fontSize': 48.0,
              'colorArgb': 0xFF000000,
            },
          ))
          .append(EditOperation.create(
            type: EditOpType.text,
            parameters: {
              'text': 'Foreground',
              'fontSize': 48.0,
              'colorArgb': 0xFFFFFFFF,
            },
          ));
      final layers = p.contentLayers;
      expect((layers[0] as TextLayer).text, 'Background');
      expect((layers[1] as TextLayer).text, 'Foreground');
    });
  });

  group('DrawingStroke brush richness', () {
    test('default values match the historical pen behaviour', () {
      const s = DrawingStroke(
        points: [StrokePoint(0, 0)],
        colorArgb: 0xFFFFFFFF,
        width: 4.0,
      );
      expect(s.opacity, 1.0);
      expect(s.hardness, 1.0);
      expect(s.brushType, DrawingBrushType.pen);
    });

    test('toJson omits identity values, includes non-default ones', () {
      const def = DrawingStroke(
        points: [StrokePoint(0, 0)],
        colorArgb: 0xFFFFFFFF,
        width: 4.0,
      );
      final defJson = def.toJson();
      expect(defJson.containsKey('opacity'), false);
      expect(defJson.containsKey('hardness'), false);
      expect(defJson.containsKey('brush'), false);

      const rich = DrawingStroke(
        points: [StrokePoint(0, 0)],
        colorArgb: 0xFFFFFFFF,
        width: 4.0,
        opacity: 0.5,
        hardness: 0.3,
        brushType: DrawingBrushType.spray,
      );
      final richJson = rich.toJson();
      expect(richJson['opacity'], 0.5);
      expect(richJson['hardness'], 0.3);
      expect(richJson['brush'], 'spray');
    });

    test('fromJson round-trips every field', () {
      const original = DrawingStroke(
        points: [StrokePoint(0.1, 0.2), StrokePoint(0.3, 0.4)],
        colorArgb: 0xFFAABBCC,
        width: 12.5,
        opacity: 0.7,
        hardness: 0.4,
        brushType: DrawingBrushType.marker,
      );
      final back = DrawingStroke.fromJson(original.toJson());
      expect(back.colorArgb, 0xFFAABBCC);
      expect(back.width, 12.5);
      expect(back.opacity, closeTo(0.7, 1e-9));
      expect(back.hardness, closeTo(0.4, 1e-9));
      expect(back.brushType, DrawingBrushType.marker);
      expect(back.points.length, 2);
    });

    test('fromJson tolerates a legacy stroke (missing optional fields)',
        () {
      // Strokes saved by older builds didn't include opacity /
      // hardness / brush. They should load with the historical
      // defaults so existing projects don't render any differently.
      final back = DrawingStroke.fromJson({
        'color': 0xFF112233,
        'width': 6.0,
        'pts': [
          [0.5, 0.5],
        ],
      });
      expect(back.colorArgb, 0xFF112233);
      expect(back.width, 6.0);
      expect(back.opacity, 1.0);
      expect(back.hardness, 1.0);
      expect(back.brushType, DrawingBrushType.pen);
    });

    test('fromJson tolerates an unknown brush name (falls back to pen)',
        () {
      final back = DrawingStroke.fromJson({
        'color': 0xFFFFFFFF,
        'width': 4.0,
        'brush': 'airbrush_v2_does_not_exist',
        'pts': const [],
      });
      expect(back.brushType, DrawingBrushType.pen);
    });

    test('fromJson clamps opacity / hardness to [0..1]', () {
      final low = DrawingStroke.fromJson({
        'color': 0xFFFFFFFF,
        'width': 4.0,
        'opacity': -0.5,
        'hardness': 2.0,
        'pts': const [],
      });
      expect(low.opacity, 0.0);
      expect(low.hardness, 1.0);
    });
  });

  group('TextLayer alignment + shadow', () {
    test('default values match the historical centered-no-shadow text', () {
      const t = TextLayer(
        id: 'id',
        text: 'hi',
        fontSize: 32,
        colorArgb: 0xFFFFFFFF,
      );
      expect(t.alignment, TextAlignment.center);
      expect(t.shadow.enabled, false);
      expect(t.shadow.colorArgb, isNull);
      expect(t.shadow.dx, 2);
      expect(t.shadow.dy, 2);
      expect(t.shadow.blur, 4);
    });

    test('toParams omits identity values', () {
      const def = TextLayer(
        id: 'id',
        text: 'hi',
        fontSize: 32,
        colorArgb: 0xFFFFFFFF,
      );
      final params = def.toParams();
      expect(params.containsKey('align'), false);
      expect(params.containsKey('shadow'), false);
    });

    test('toParams includes alignment when non-default', () {
      const left = TextLayer(
        id: 'id',
        text: 'hi',
        fontSize: 32,
        colorArgb: 0xFFFFFFFF,
        alignment: TextAlignment.left,
      );
      expect(left.toParams()['align'], 'left');
    });

    test('toParams includes shadow only when enabled', () {
      const off = TextLayer(
        id: 'id',
        text: 'hi',
        fontSize: 32,
        colorArgb: 0xFFFFFFFF,
        shadow: TextShadow(dx: 5, dy: 5),
      );
      // Shadow values set but enabled=false → still omitted from
      // saved params because the shadow does nothing visually.
      expect(off.toParams().containsKey('shadow'), false);

      const on = TextLayer(
        id: 'id',
        text: 'hi',
        fontSize: 32,
        colorArgb: 0xFFFFFFFF,
        shadow: TextShadow(enabled: true, dx: 5, dy: 5, blur: 8),
      );
      final params = on.toParams();
      expect(params['shadow'], isA<Map>());
      final s = params['shadow'] as Map<String, dynamic>;
      expect(s['enabled'], true);
      expect(s['dx'], 5);
      expect(s['dy'], 5);
      expect(s['blur'], 8);
    });

    test('fromOp / toParams round-trip every new field', () {
      const original = TextLayer(
        id: 'id',
        text: 'rich',
        fontSize: 48,
        colorArgb: 0xFFFF8800,
        alignment: TextAlignment.right,
        shadow: TextShadow(
          enabled: true,
          colorArgb: 0xFF000000,
          dx: -3,
          dy: 5,
          blur: 6,
        ),
      );
      final back = TextLayer.fromOp(
        EditOperation.create(
          type: EditOpType.text,
          parameters: original.toParams(),
        ).copyWith(id: 'id'),
      );
      expect(back.alignment, TextAlignment.right);
      expect(back.shadow.enabled, true);
      expect(back.shadow.colorArgb, 0xFF000000);
      expect(back.shadow.dx, -3);
      expect(back.shadow.dy, 5);
      expect(back.shadow.blur, 6);
    });

    test('fromOp tolerates legacy text ops missing align / shadow', () {
      // Text layers saved by older builds didn't carry these fields.
      final back = TextLayer.fromOp(
        EditOperation.create(
          type: EditOpType.text,
          parameters: {
            'text': 'legacy',
            'fontSize': 24,
            'colorArgb': 0xFFFFFFFF,
          },
        ),
      );
      expect(back.alignment, TextAlignment.center);
      expect(back.shadow.enabled, false);
    });

    test('fromOp falls back to center for unknown alignment names', () {
      final back = TextLayer.fromOp(
        EditOperation.create(
          type: EditOpType.text,
          parameters: {
            'text': 'x',
            'fontSize': 24,
            'colorArgb': 0xFFFFFFFF,
            'align': 'justify_full_does_not_exist',
          },
        ),
      );
      expect(back.alignment, TextAlignment.center);
    });

    test('TextShadow.copyWith preserves untouched fields', () {
      const s = TextShadow(
        enabled: true,
        colorArgb: 0xFF000000,
        dx: 2,
        dy: 3,
        blur: 4,
      );
      final next = s.copyWith(blur: 10);
      expect(next.enabled, true);
      expect(next.dx, 2);
      expect(next.dy, 3);
      expect(next.blur, 10);
      expect(next.colorArgb, 0xFF000000);
    });

    test('TextShadow.kAutoColorArgb is a sensible default', () {
      // Black at ~60% alpha so the shadow reads on light text over
      // a typical photo without the user picking a colour.
      expect(TextShadow.kAutoColorArgb >> 24 & 0xff, greaterThan(100));
      expect(TextShadow.kAutoColorArgb & 0xffffff, 0);
    });
  });
}
