import 'package:flutter_test/flutter_test.dart';

import 'package:image_editor/engine/pipeline/edit_op_type.dart';
import 'package:image_editor/engine/pipeline/edit_operation.dart';
import 'package:image_editor/engine/pipeline/edit_pipeline.dart';
import 'package:image_editor/engine/pipeline/pipeline_extensions.dart';
import 'package:image_editor/engine/pipeline/pipeline_serializer.dart';

/// XVI.46 reader/writer round-trip.
///
/// Pin: an `EditOpType.lensDistortion` op with `k1` / `k2` doubles
/// survives the JSON serialiser and reads back identically. This
/// guards against the same paramKey-typo-class regression XVI.22
/// fixed for `levels`.
void main() {
  group('lensDistortion op (paramKey="k1"/"k2") round-trip', () {
    test('k1 + k2 survive JSON encode/decode', () {
      final op = EditOperation.create(
        type: EditOpType.lensDistortion,
        parameters: const {'k1': -0.08, 'k2': 0.012},
      );
      final pipeline = EditPipeline.forOriginal('/tmp/x.jpg').append(op);

      final serializer = PipelineSerializer();
      final encoded = serializer.encodeJsonString(pipeline);
      final decoded = serializer.decodeJsonString(encoded);

      expect(decoded.operations, hasLength(1));
      final restoredOp = decoded.operations.first;
      expect(restoredOp.type, EditOpType.lensDistortion);
      expect(restoredOp.doubleParam('k1'), closeTo(-0.08, 1e-9));
      expect(restoredOp.doubleParam('k2'), closeTo(0.012, 1e-9));
    });

    test('reader reads default 0 for missing keys', () {
      final op = EditOperation.create(
        type: EditOpType.lensDistortion,
        parameters: const {},
      );
      // Reading via the same convention the pass builder uses.
      expect(op.doubleParam('k1'), 0.0);
      expect(op.doubleParam('k2'), 0.0);
    });

    test('round-trip survives findOp lookup', () {
      final op = EditOperation.create(
        type: EditOpType.lensDistortion,
        parameters: const {'k1': -0.12, 'k2': 0.0},
      );
      final pipeline = EditPipeline.forOriginal('/tmp/y.jpg').append(op);
      final found = pipeline.findOp(EditOpType.lensDistortion);
      expect(found, isNotNull);
      expect(found!.doubleParam('k1'), closeTo(-0.12, 1e-9));
    });
  });
}
