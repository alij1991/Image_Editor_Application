import 'package:flutter_test/flutter_test.dart';

import 'package:image_editor/engine/pipeline/edit_op_type.dart';
import 'package:image_editor/engine/pipeline/edit_operation.dart';
import 'package:image_editor/engine/pipeline/edit_pipeline.dart';
import 'package:image_editor/engine/pipeline/op_registry.dart';
import 'package:image_editor/engine/pipeline/op_spec.dart';
import 'package:image_editor/engine/pipeline/pipeline_extensions.dart';

/// Phase XVI.23 — pin the OpSpec ↔ reader contract for the new
/// Texture slider so it can't drift the way gamma did (XVI.22).
///
/// Specifically: the slider's OpSpec writes to `EditOpType.texture`
/// with paramKey `'value'`, and `pipeline.textureValue` MUST read
/// from that exact (type, key) pair. The four checks below pin the
/// path slider→pipeline→reader.
void main() {
  group('texture reader (XVI.23)', () {
    test('returns identity (0.0) on an empty pipeline', () {
      final pipeline = EditPipeline.forOriginal('');
      expect(pipeline.textureValue, 0.0);
    });

    test('reads the slider-written value from a texture op', () {
      // Mirrors what LightroomPanel does when the user drags the
      // Texture slider to +0.6.
      final op = EditOperation.create(
        type: EditOpType.texture,
        parameters: {'value': 0.6},
      );
      final pipeline = EditPipeline.forOriginal('').append(op);
      expect(pipeline.textureValue, closeTo(0.6, 1e-9));
    });

    test('disabled texture op falls back to identity', () {
      final op = EditOperation.create(
        type: EditOpType.texture,
        parameters: {'value': 0.8},
      ).copyWith(enabled: false);
      final pipeline = EditPipeline.forOriginal('').append(op);
      expect(pipeline.textureValue, 0.0);
    });

    test('OpSpec metadata pins the (type, paramKey) contract', () {
      // The reader-writer mismatch that broke gamma (XVI.22) only
      // shows up if the OpSpec.paramKey drifts from the reader's
      // expectation. Pin both sides here so a future edit can't
      // silently re-introduce the typo.
      final spec = OpSpecs.byType(EditOpType.texture);
      expect(spec, isNotNull,
          reason: 'EditOpType.texture must have a default OpSpec '
              'with paramKey="value"');
      expect(spec!.paramKey, 'value');
      expect(spec.identity, 0.0);
      expect(spec.min, -1.0);
      expect(spec.max, 1.0);
      expect(spec.category, OpCategory.light);
    });

    test('OpRegistry classifies texture as a shader-pass + preset-replaceable op',
        () {
      // If shaderPass: false, the matrix composer would try to fold
      // texture into the colour matrix and silently drop it. If
      // presetReplaceable: false, presets that include texture would
      // fail to overwrite a user-set texture value on apply.
      final reg = OpRegistry.forType(EditOpType.texture);
      expect(reg, isNotNull);
      expect(reg!.shaderPass, isTrue);
      expect(reg.presetReplaceable, isTrue);
      expect(reg.matrixComposable, isFalse);
    });
  });
}
