import 'package:flutter_test/flutter_test.dart';

import 'package:image_editor/engine/pipeline/edit_op_type.dart';
import 'package:image_editor/engine/pipeline/edit_operation.dart';
import 'package:image_editor/engine/pipeline/edit_pipeline.dart';
import 'package:image_editor/engine/pipeline/pipeline_extensions.dart';

/// Phase XVI.22 regression test — the gamma slider's persisted value
/// is read back through `EditPipelineExtensions.levelsGamma`.
///
/// Pre-XVI.22 the reader looked at a non-existent `EditOpType.gamma`
/// op with key `'value'`, while the slider OpSpec wrote to
/// `EditOpType.levels` with key `'gamma'`. Result: the gamma slider
/// was a no-op for the lifetime of the project — every value the user
/// dragged to silently degraded back to identity (1.0) before the
/// shader pass picked it up.
///
/// This test pins the slider → reader contract so that future op
/// registrations can't break gamma again.
void main() {
  group('levelsGamma reader (XVI.22)', () {
    test('returns identity (1.0) on an empty pipeline', () {
      final pipeline = EditPipeline.forOriginal('');
      expect(pipeline.levelsGamma, 1.0);
    });

    test('reads the slider-written value from a levels op', () {
      // Mirrors what the LightroomPanel slider does when the user
      // drags the Gamma slider to 1.7 — see op_registry.dart line
      // 274-289 (OpSpec(type: levels, paramKey: 'gamma', ...)).
      final op = EditOperation.create(
        type: EditOpType.levels,
        parameters: {'gamma': 1.7},
      );
      final pipeline = EditPipeline.forOriginal('').append(op);
      expect(pipeline.levelsGamma, closeTo(1.7, 1e-9));
    });

    test('reads black, white, gamma from the same levels op', () {
      // Real-world usage — black/white/gamma are three sliders
      // sharing one op so the LevelsGamma shader fires once with all
      // three params. This pins that the readers don't accidentally
      // diverge.
      final op = EditOperation.create(
        type: EditOpType.levels,
        parameters: {
          'black': 0.05,
          'white': 0.95,
          'gamma': 0.6,
        },
      );
      final pipeline = EditPipeline.forOriginal('').append(op);
      expect(pipeline.levelsBlack, closeTo(0.05, 1e-9));
      expect(pipeline.levelsWhite, closeTo(0.95, 1e-9));
      expect(pipeline.levelsGamma, closeTo(0.6, 1e-9));
    });

    test('disabled levels op falls back to identity', () {
      final op = EditOperation.create(
        type: EditOpType.levels,
        parameters: {'gamma': 2.5},
      ).copyWith(enabled: false);
      final pipeline = EditPipeline.forOriginal('').append(op);
      // hasEnabledOp returns false → reader uses identity default.
      expect(pipeline.levelsGamma, 1.0);
    });

    test('legacy EditOpType.gamma op is ignored (does NOT feed reader)',
        () {
      // Hostile back-compat: an old / hand-edited pipeline with the
      // legacy EditOpType.gamma key=value layout that the buggy reader
      // used to look at. The new reader reads from levels.gamma only,
      // so this op contributes nothing — same result as identity.
      final op = EditOperation.create(
        type: EditOpType.gamma,
        parameters: {'value': 3.0},
      );
      final pipeline = EditPipeline.forOriginal('').append(op);
      expect(pipeline.levelsGamma, 1.0,
          reason:
              'levels.gamma is the canonical key after XVI.22; the dead '
              'EditOpType.gamma type stays registered for back-compat '
              'but no longer feeds the shader pass.');
    });
  });
}
