import 'package:flutter_test/flutter_test.dart';

import 'package:image_editor/engine/pipeline/edit_op_type.dart';
import 'package:image_editor/engine/pipeline/edit_operation.dart';
import 'package:image_editor/engine/pipeline/edit_pipeline.dart';

/// Covers the B2 audit fix: `EditPipeline.reorderLayers` must preserve
/// non-layer op positions when shuffling layer ops within a pipeline
/// that contains adjustment ops interleaved with layers.
void main() {
  bool isLayer(EditOperation op) =>
      op.type == EditOpType.text ||
      op.type == EditOpType.sticker ||
      op.type == EditOpType.drawing;

  EditOperation colorOp(String type, double value) =>
      EditOperation.create(type: type, parameters: {'value': value});

  EditOperation textOp(String text) => EditOperation.create(
        type: EditOpType.text,
        parameters: {
          'text': text,
          'fontSize': 48.0,
          'colorArgb': 0xFFFFFFFF,
        },
      );

  group('EditPipeline.findById', () {
    test('returns matching op regardless of enabled state', () {
      final p = EditPipeline.forOriginal('/tmp/img.jpg').append(
        textOp('hello'),
      );
      final id = p.operations.first.id;
      expect(p.findById(id)?.parameters['text'], 'hello');
      // Disable it and look up again.
      final disabled = p.toggleEnabled(id);
      expect(disabled.findById(id)?.enabled, false);
      expect(disabled.findById(id)?.parameters['text'], 'hello');
    });

    test('returns null for unknown id', () {
      final p = EditPipeline.forOriginal('/tmp/img.jpg');
      expect(p.findById('does-not-exist'), isNull);
    });
  });

  group('EditPipeline.reorderLayers', () {
    test('noop when layerId not found', () {
      final p = EditPipeline.forOriginal('/tmp/img.jpg').append(textOp('a'));
      final result = p.reorderLayers(
        layerId: 'not-in-pipeline',
        newLayerIndex: 0,
        isLayer: isLayer,
      );
      expect(result, same(p));
    });

    test('noop when target equals current layer index', () {
      final p = EditPipeline.forOriginal('/tmp/img.jpg')
          .append(textOp('a'))
          .append(textOp('b'));
      final firstId = p.operations.first.id;
      final result = p.reorderLayers(
        layerId: firstId,
        newLayerIndex: 0,
        isLayer: isLayer,
      );
      expect(result, same(p));
    });

    test('moves a layer within a pure-layer pipeline', () {
      final a = textOp('A');
      final b = textOp('B');
      final c = textOp('C');
      final p = EditPipeline.forOriginal('/tmp/img.jpg')
          .append(a)
          .append(b)
          .append(c);
      // Move C (layer index 2) to layer index 0 (bottom).
      final result = p.reorderLayers(
        layerId: c.id,
        newLayerIndex: 0,
        isLayer: isLayer,
      );
      expect(result.operations.map((o) => o.id).toList(), [
        c.id,
        a.id,
        b.id,
      ]);
    });

    test('preserves non-layer op positions when shuffling layers', () {
      // Pipeline: [brightness, text1, contrast, text2, saturation, text3]
      // Layer ops are at pipeline indices [1, 3, 5].
      // Move text3 (layer index 2) to layer index 0 (bottom of stack).
      // Expected pipeline: [brightness, text3, contrast, text1, saturation, text2]
      //   (layers rearranged to [text3, text1, text2], non-layer ops fixed)
      final br = colorOp(EditOpType.brightness, 0.2);
      final t1 = textOp('t1');
      final co = colorOp(EditOpType.contrast, 0.1);
      final t2 = textOp('t2');
      final sa = colorOp(EditOpType.saturation, 0.3);
      final t3 = textOp('t3');
      final p = EditPipeline.forOriginal('/tmp/img.jpg')
          .append(br)
          .append(t1)
          .append(co)
          .append(t2)
          .append(sa)
          .append(t3);
      final result = p.reorderLayers(
        layerId: t3.id,
        newLayerIndex: 0,
        isLayer: isLayer,
      );
      expect(
        result.operations.map((o) => o.id).toList(),
        [br.id, t3.id, co.id, t1.id, sa.id, t2.id],
      );
      // Non-layer types stay at their original positions.
      expect(result.operations[0].type, EditOpType.brightness);
      expect(result.operations[2].type, EditOpType.contrast);
      expect(result.operations[4].type, EditOpType.saturation);
    });

    test('clamps out-of-range target to last valid layer index', () {
      final a = textOp('A');
      final b = textOp('B');
      final p = EditPipeline.forOriginal('/tmp/img.jpg').append(a).append(b);
      final result = p.reorderLayers(
        layerId: a.id,
        newLayerIndex: 99,
        isLayer: isLayer,
      );
      expect(result.operations.map((o) => o.id).toList(), [b.id, a.id]);
    });

    test('moving a layer to its neighbor swaps them', () {
      final br = colorOp(EditOpType.brightness, 0.1);
      final a = textOp('A');
      final b = textOp('B');
      final p = EditPipeline.forOriginal('/tmp/img.jpg')
          .append(br)
          .append(a)
          .append(b);
      // Swap A and B; brightness must stay at index 0.
      final result = p.reorderLayers(
        layerId: a.id,
        newLayerIndex: 1,
        isLayer: isLayer,
      );
      expect(result.operations.map((o) => o.id).toList(),
          [br.id, b.id, a.id]);
    });

    // IX.A.3 — extra edge cases to close the `[test-gap]` entry.
    test('all-non-layer pipeline returns identity on reorder attempt', () {
      final br = colorOp(EditOpType.brightness, 0.2);
      final co = colorOp(EditOpType.contrast, 0.1);
      final p = EditPipeline.forOriginal('/tmp/img.jpg')
          .append(br)
          .append(co);
      // Attempt to move a layer that doesn't exist in this pipeline.
      final result = p.reorderLayers(
        layerId: 'fake-layer',
        newLayerIndex: 0,
        isLayer: isLayer,
      );
      expect(result, same(p));
      // Operations untouched, still in original order.
      expect(result.operations.map((o) => o.type).toList(),
          [EditOpType.brightness, EditOpType.contrast]);
    });

    test(
        'adjacent layers (no non-layer ops between) reorder without '
        'disturbing a trailing non-layer op', () {
      final a = textOp('A');
      final b = textOp('B');
      final sa = colorOp(EditOpType.saturation, 0.3);
      final p = EditPipeline.forOriginal('/tmp/img.jpg')
          .append(a)
          .append(b)
          .append(sa);
      final result = p.reorderLayers(
        layerId: b.id,
        newLayerIndex: 0,
        isLayer: isLayer,
      );
      expect(result.operations.map((o) => o.id).toList(),
          [b.id, a.id, sa.id]);
      // Saturation stays at its final pipeline slot.
      expect(result.operations[2].type, EditOpType.saturation);
    });

    test('non-layer ops at both ends survive a layer reorder', () {
      // [brightness, text1, text2, saturation]
      //   → reorder layers so text2 precedes text1
      // expected: [brightness, text2, text1, saturation]
      final br = colorOp(EditOpType.brightness, 0.1);
      final t1 = textOp('t1');
      final t2 = textOp('t2');
      final sa = colorOp(EditOpType.saturation, 0.2);
      final p = EditPipeline.forOriginal('/tmp/img.jpg')
          .append(br)
          .append(t1)
          .append(t2)
          .append(sa);
      final result = p.reorderLayers(
        layerId: t2.id,
        newLayerIndex: 0,
        isLayer: isLayer,
      );
      expect(result.operations.map((o) => o.id).toList(),
          [br.id, t2.id, t1.id, sa.id]);
      // Non-layer boundaries unchanged.
      expect(result.operations.first.type, EditOpType.brightness);
      expect(result.operations.last.type, EditOpType.saturation);
    });

    test('mixed layer types (text + sticker + drawing) reorder together',
        () {
      final stickerOp = EditOperation.create(
        type: EditOpType.sticker,
        parameters: {
          'character': '\u2605',
          'x': 0.5,
          'y': 0.5,
          'fontSize': 48.0,
        },
      );
      final drawOp = EditOperation.create(
        type: EditOpType.drawing,
        parameters: {'strokes': <Object>[]},
      );
      final t = textOp('t');
      final br = colorOp(EditOpType.brightness, 0.1);
      // Layer stack (bottom→top): text, sticker, drawing.
      // Pipeline order: [brightness, text, sticker, drawing]
      final p = EditPipeline.forOriginal('/tmp/img.jpg')
          .append(br)
          .append(t)
          .append(stickerOp)
          .append(drawOp);
      // Move drawing (layer index 2) to the bottom (layer index 0).
      final result = p.reorderLayers(
        layerId: drawOp.id,
        newLayerIndex: 0,
        isLayer: isLayer,
      );
      // Expected layer order: [drawing, text, sticker] with brightness
      // still at pipeline index 0.
      expect(result.operations.map((o) => o.id).toList(),
          [br.id, drawOp.id, t.id, stickerOp.id]);
    });
  });
}
