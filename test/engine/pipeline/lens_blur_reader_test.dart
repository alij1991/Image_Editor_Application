import 'package:flutter_test/flutter_test.dart';

import 'package:image_editor/engine/pipeline/edit_op_type.dart';
import 'package:image_editor/engine/pipeline/edit_operation.dart';
import 'package:image_editor/engine/pipeline/edit_pipeline.dart';
import 'package:image_editor/engine/pipeline/pipeline_extensions.dart';
import 'package:image_editor/engine/pipeline/pipeline_serializer.dart';

/// Phase XVI.40 reader/writer round-trip for the new `lensBlur` op.
///
/// Pin: an `EditOpType.lensBlur` op with `aperture` / `focusX` /
/// `focusY` / `bokehShape` survives the JSON serialiser and reads
/// back identically. Same paramKey-typo guard the XVI.22 fix
/// established for `levels` and the XVI.46 test established for
/// `lensDistortion`.
void main() {
  group('lensBlur op (multi-paramKey) round-trip', () {
    test('all four params survive JSON encode/decode', () {
      final op = EditOperation.create(
        type: EditOpType.lensBlur,
        parameters: const {
          'aperture': 0.7,
          'focusX': 0.42,
          'focusY': 0.58,
          'bokehShape': 1.0, // 5-blade
        },
      );
      final pipeline = EditPipeline.forOriginal('/tmp/x.jpg').append(op);

      final serializer = PipelineSerializer();
      final encoded = serializer.encodeJsonString(pipeline);
      final decoded = serializer.decodeJsonString(encoded);

      expect(decoded.operations, hasLength(1));
      final restored = decoded.operations.first;
      expect(restored.type, EditOpType.lensBlur);
      expect(restored.doubleParam('aperture'), closeTo(0.7, 1e-9));
      expect(restored.doubleParam('focusX'), closeTo(0.42, 1e-9));
      expect(restored.doubleParam('focusY'), closeTo(0.58, 1e-9));
      expect(restored.doubleParam('bokehShape'), closeTo(1.0, 1e-9));
    });

    test('reader reads default identities for missing keys', () {
      final op = EditOperation.create(
        type: EditOpType.lensBlur,
        parameters: const {},
      );
      // Pass-builder reads with `doubleParam('focusX', 0.5)` style
      // fallbacks. Test the reader keys.
      expect(op.doubleParam('aperture'), 0.0);
      expect(op.doubleParam('focusX', 0.5), 0.5);
      expect(op.doubleParam('focusY', 0.5), 0.5);
      expect(op.doubleParam('bokehShape'), 0.0);
    });

    test('round-trip survives findOp lookup', () {
      final op = EditOperation.create(
        type: EditOpType.lensBlur,
        parameters: const {
          'aperture': 0.5,
          'focusX': 0.5,
          'focusY': 0.5,
          'bokehShape': 2.0, // cat's-eye
        },
      );
      final pipeline = EditPipeline.forOriginal('/tmp/y.jpg').append(op);
      final found = pipeline.findOp(EditOpType.lensBlur);
      expect(found, isNotNull);
      expect(found!.doubleParam('aperture'), closeTo(0.5, 1e-9));
      expect(found.doubleParam('bokehShape'), closeTo(2.0, 1e-9));
    });

    test('aperture below noise floor still round-trips', () {
      // Even an effectively-zero aperture must serialise — the user
      // may want to bump it via undo without losing the shape choice.
      final op = EditOperation.create(
        type: EditOpType.lensBlur,
        parameters: const {
          'aperture': 0.0001,
          'focusX': 0.3,
          'focusY': 0.7,
          'bokehShape': 0.0, // circle
        },
      );
      final pipeline = EditPipeline.forOriginal('/tmp/z.jpg').append(op);

      final serializer = PipelineSerializer();
      final decoded =
          serializer.decodeJsonString(serializer.encodeJsonString(pipeline));
      final restored = decoded.operations.first;
      expect(restored.doubleParam('aperture'), closeTo(0.0001, 1e-9));
      expect(restored.doubleParam('focusX'), closeTo(0.3, 1e-9));
      expect(restored.doubleParam('focusY'), closeTo(0.7, 1e-9));
    });
  });
}
