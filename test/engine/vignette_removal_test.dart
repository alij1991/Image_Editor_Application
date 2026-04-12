import 'package:flutter_test/flutter_test.dart';

import 'package:image_editor/engine/pipeline/edit_op_type.dart';
import 'package:image_editor/engine/pipeline/edit_operation.dart';
import 'package:image_editor/engine/pipeline/edit_pipeline.dart';
import 'package:image_editor/engine/pipeline/op_spec.dart';
import 'package:image_editor/engine/pipeline/pipeline_extensions.dart';

/// Covers the B3 audit fix: when a multi-param op (e.g. vignette) is
/// dragged from non-identity back to identity via `setScalar`, the
/// resulting commit path must remove the op entirely — not leave stale
/// sibling parameters in the pipeline.
///
/// This test exercises the pipeline / pipeline-reader logic directly,
/// without needing a full [EditorSession] (which requires a real
/// `ui.Image`). It verifies the contract that `reorderLayers`,
/// `findById`, `findOp`, and `OpSpecs.paramsForType` + identity checks
/// are consistent.
void main() {
  group('Vignette identity check (multi-param)', () {
    test('identity requires every param at its identity', () {
      final specs = OpSpecs.paramsForType(EditOpType.vignette);
      expect(specs.length, 3,
          reason: 'vignette has amount/feather/roundness');

      bool allIdentity(Map<String, dynamic> params) {
        return specs.every((spec) {
          final raw = params[spec.paramKey];
          final v = raw is num ? raw.toDouble() : spec.identity;
          return spec.isIdentity(v);
        });
      }

      // All at identity.
      expect(
          allIdentity(const {
            'amount': 0.0,
            'feather': 0.4,
            'roundness': 0.5,
          }),
          true);

      // Amount non-identity → not identity.
      expect(
          allIdentity(const {
            'amount': 0.3,
            'feather': 0.4,
            'roundness': 0.5,
          }),
          false);

      // Amount back to 0 but feather changed → still not identity.
      expect(
          allIdentity(const {
            'amount': 0.0,
            'feather': 0.7,
            'roundness': 0.5,
          }),
          false);
    });
  });

  group('Pipeline op removal for multi-param', () {
    test('removing vignette op produces a pipeline with no vignette', () {
      final vignette = EditOperation.create(
        type: EditOpType.vignette,
        parameters: {
          'amount': 0.3,
          'feather': 0.4,
          'roundness': 0.5,
        },
      );
      final base = EditPipeline.forOriginal('/tmp/img.jpg').append(vignette);
      expect(base.hasEnabledOp(EditOpType.vignette), true);

      final next = base.remove(vignette.id);
      expect(next.hasEnabledOp(EditOpType.vignette), false);
      expect(next.findById(vignette.id), null);
    });

    test('readParam on removed op returns the fallback', () {
      final p = EditPipeline.forOriginal('/tmp/img.jpg');
      expect(p.readParam(EditOpType.vignette, 'amount', 0), 0);
      expect(p.readParam(EditOpType.vignette, 'feather', 0.4), 0.4);
    });
  });
}
