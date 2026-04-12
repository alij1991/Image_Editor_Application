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
}
