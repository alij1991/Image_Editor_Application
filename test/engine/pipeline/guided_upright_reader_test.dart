import 'package:flutter_test/flutter_test.dart';

import 'package:image_editor/engine/geometry/guided_upright.dart';
import 'package:image_editor/engine/pipeline/edit_op_type.dart';
import 'package:image_editor/engine/pipeline/edit_operation.dart';
import 'package:image_editor/engine/pipeline/edit_pipeline.dart';
import 'package:image_editor/engine/pipeline/pipeline_extensions.dart';
import 'package:image_editor/engine/pipeline/pipeline_serializer.dart';

/// XVI.45 reader/writer round-trip.
///
/// Pin: an `EditOpType.guidedUpright` op with a `lines` parameter
/// survives the JSON serialiser and reads back identically. This
/// guards against the XVI.22-style typo where a paramKey diverged
/// silently between writer and reader.
void main() {
  group('guidedUpright op (paramKey="lines") reader/writer round-trip', () {
    test('lines list survives JSON round-trip', () {
      final input = [
        const GuidedUprightLine(x1: 0.10, y1: 0.30, x2: 0.90, y2: 0.34),
        const GuidedUprightLine(x1: 0.10, y1: 0.70, x2: 0.90, y2: 0.66),
        const GuidedUprightLine(x1: 0.30, y1: 0.10, x2: 0.32, y2: 0.90),
        const GuidedUprightLine(x1: 0.70, y1: 0.10, x2: 0.68, y2: 0.90),
      ];
      final op = EditOperation.create(
        type: EditOpType.guidedUpright,
        parameters: {'lines': GuidedUprightLineCodec.encode(input)},
      );
      final pipeline = EditPipeline.forOriginal('/tmp/x.jpg').append(op);

      // Encode → decode through the canonical serializer the
      // auto-save path uses.
      final serializer = PipelineSerializer();
      final encoded = serializer.encodeJsonString(pipeline);
      final decoded = serializer.decodeJsonString(encoded);

      expect(decoded.operations, hasLength(1));
      final restoredOp = decoded.operations.first;
      expect(restoredOp.type, EditOpType.guidedUpright);

      final restoredLines = GuidedUprightLineCodec.decode(
        restoredOp.parameters['lines'],
      );
      expect(restoredLines, equals(input));
    });

    test('reader rejects malformed entries without losing valid ones', () {
      final mixed = [
        [0.1, 0.2, 0.3, 0.4], // valid
        [1, 2], // too short — drop
        [0.5, 0.5, 0.55, 0.95], // valid
      ];
      final op = EditOperation.create(
        type: EditOpType.guidedUpright,
        parameters: {'lines': mixed},
      );

      final lines = GuidedUprightLineCodec.decode(op.parameters['lines']);
      expect(lines, hasLength(2));
      expect(lines[0].x1, 0.1);
      expect(lines[1].x1, 0.5);
    });

    test('reader handles missing `lines` parameter', () {
      final op = EditOperation.create(
        type: EditOpType.guidedUpright,
        parameters: const {},
      );
      final lines = GuidedUprightLineCodec.decode(op.parameters['lines']);
      expect(lines, isEmpty);
    });

    test('reader round-trips through pipeline.findOp', () {
      const guide = GuidedUprightLine(
          x1: 0.1, y1: 0.5, x2: 0.9, y2: 0.55);
      final op = EditOperation.create(
        type: EditOpType.guidedUpright,
        parameters: {
          'lines': GuidedUprightLineCodec.encode([guide]),
        },
      );
      final pipeline = EditPipeline.forOriginal('/tmp/y.jpg').append(op);

      final found = pipeline.findOp(EditOpType.guidedUpright);
      expect(found, isNotNull);
      final lines = GuidedUprightLineCodec.decode(found!.parameters['lines']);
      expect(lines, [guide]);
    });
  });
}
