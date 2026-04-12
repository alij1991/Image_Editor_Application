import 'package:flutter_test/flutter_test.dart';

import 'package:image_editor/engine/pipeline/edit_op_type.dart';
import 'package:image_editor/engine/pipeline/edit_operation.dart';
import 'package:image_editor/engine/pipeline/edit_pipeline.dart';
import 'package:image_editor/engine/pipeline/mask_data.dart';
import 'package:image_editor/engine/pipeline/pipeline_serializer.dart';

void main() {
  group('EditPipeline', () {
    test('append / remove / replace / reorder', () {
      final op1 = EditOperation.create(
        type: EditOpType.brightness,
        parameters: {'value': 0.1},
      );
      final op2 = EditOperation.create(
        type: EditOpType.contrast,
        parameters: {'value': 0.2},
      );
      final op3 = EditOperation.create(
        type: EditOpType.saturation,
        parameters: {'value': -0.1},
      );

      var p = EditPipeline.forOriginal('/tmp/img.jpg');
      p = p.append(op1).append(op2).append(op3);
      expect(p.operations.length, 3);
      expect(p.activeCount, 3);

      p = p.toggleEnabled(op2.id);
      expect(p.operations[1].enabled, false);
      expect(p.activeCount, 2);

      p = p.reorder(0, 2);
      expect(p.operations[0].id, op2.id);
      expect(p.operations[1].id, op3.id);
      expect(p.operations[2].id, op1.id);

      p = p.remove(op3.id);
      expect(p.operations.length, 2);
      expect(p.operations.any((o) => o.id == op3.id), false);
    });

    test('setAllEnabled', () {
      var p = EditPipeline.forOriginal('/tmp/img.jpg');
      p = p.append(EditOperation.create(
        type: EditOpType.brightness,
        parameters: {'value': 0.1},
      ));
      p = p.append(EditOperation.create(
        type: EditOpType.contrast,
        parameters: {'value': 0.1},
      ));
      expect(p.activeCount, 2);
      p = p.setAllEnabled(false);
      expect(p.activeCount, 0);
      p = p.setAllEnabled(true);
      expect(p.activeCount, 2);
    });
  });

  group('PipelineSerializer', () {
    final serializer = PipelineSerializer();

    test('roundtrip small pipeline (plain marker)', () {
      final pipeline = EditPipeline.forOriginal('/tmp/img.jpg').append(
        EditOperation.create(
          type: EditOpType.brightness,
          parameters: {'value': 0.25},
        ),
      );

      final bytes = serializer.encode(pipeline);
      expect(bytes.first, 0x00); // plain marker for small payload

      final decoded = serializer.decode(bytes);
      expect(decoded.operations.length, 1);
      expect(decoded.operations.first.type, EditOpType.brightness);
      expect(decoded.operations.first.parameters['value'], 0.25);
      expect(decoded.originalImagePath, '/tmp/img.jpg');
    });

    test('roundtrip preserves mask data', () {
      final op = EditOperation.create(
        type: EditOpType.vibrance,
        parameters: {'value': 0.5},
        mask: const MaskData(
          kind: MaskKind.radialGradient,
          feather: 0.2,
          parameters: {'cx': 0.5, 'cy': 0.5, 'radius': 0.3},
        ),
      );
      final pipeline = EditPipeline.forOriginal('/tmp/img.jpg').append(op);

      final encoded = serializer.encodeJsonString(pipeline);
      final decoded = serializer.decodeJsonString(encoded);
      final decodedOp = decoded.operations.single;
      expect(decodedOp.mask?.kind, MaskKind.radialGradient);
      expect(decodedOp.mask?.feather, closeTo(0.2, 1e-9));
      expect(decodedOp.mask?.parameters['radius'], 0.3);
    });

    test('gzip path triggers for large payloads', () {
      var pipeline = EditPipeline.forOriginal('/tmp/img.jpg');
      // Build a pipeline with enough ops to exceed the 64 KB threshold.
      for (int i = 0; i < 2000; i++) {
        pipeline = pipeline.append(EditOperation.create(
          type: EditOpType.brightness,
          parameters: {
            'value': i * 0.0001,
            'filler': List.generate(20, (j) => 'x' * 4),
          },
        ));
      }
      final bytes = serializer.encode(pipeline);
      expect(bytes.first, 0x01); // gzip marker

      final decoded = serializer.decode(bytes);
      expect(decoded.operations.length, 2000);
    });

    test('schema version is stamped on encode', () {
      final pipeline = EditPipeline.forOriginal('/tmp/img.jpg');
      final json = serializer.encodeJsonString(pipeline);
      expect(json.contains('"version":'), true);
    });
  });
}
