import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';

import 'package:image_editor/engine/pipeline/edit_op_type.dart';
import 'package:image_editor/engine/pipeline/edit_operation.dart';
import 'package:image_editor/engine/pipeline/edit_pipeline.dart';
import 'package:image_editor/engine/pipeline/geometry_state.dart';
import 'package:image_editor/engine/pipeline/pipeline_extensions.dart';

void main() {
  group('GeometryState', () {
    test('identity has no rotation / flip / straighten', () {
      const g = GeometryState.identity;
      expect(g.isIdentity, true);
      expect(g.rotationStepsNormalized, 0);
      expect(g.straightenRadians, 0);
      expect(g.flipH, false);
      expect(g.flipV, false);
      expect(g.swapsAspect, false);
    });

    test('rotation steps normalize to [0, 3]', () {
      expect(const GeometryState(rotationSteps: 4).rotationStepsNormalized, 0);
      expect(const GeometryState(rotationSteps: 5).rotationStepsNormalized, 1);
      expect(const GeometryState(rotationSteps: -1).rotationStepsNormalized, 3);
      expect(const GeometryState(rotationSteps: -4).rotationStepsNormalized, 0);
    });

    test('swapsAspect true at 90° and 270°', () {
      expect(const GeometryState(rotationSteps: 1).swapsAspect, true);
      expect(const GeometryState(rotationSteps: 3).swapsAspect, true);
      expect(const GeometryState(rotationSteps: 0).swapsAspect, false);
      expect(const GeometryState(rotationSteps: 2).swapsAspect, false);
    });

    test('straightenRadians converts degrees correctly', () {
      const g = GeometryState(straightenDegrees: 30);
      expect(g.straightenRadians, closeTo(30 * math.pi / 180, 1e-9));
    });

    test('copyWith preserves siblings', () {
      const g = GeometryState(
        rotationSteps: 1,
        straightenDegrees: 12,
        flipH: true,
        cropAspectRatio: 4 / 3,
      );
      final flipped = g.copyWith(flipV: true);
      expect(flipped.rotationSteps, 1);
      expect(flipped.straightenDegrees, 12);
      expect(flipped.flipH, true);
      expect(flipped.flipV, true);
      expect(flipped.cropAspectRatio, 4 / 3);
    });

    test('copyWith can clear nullable crop aspect ratio', () {
      const g = GeometryState(cropAspectRatio: 1.0);
      final cleared = g.copyWith(cropAspectRatio: null);
      expect(cleared.cropAspectRatio, null);
    });

    test('equality holds on normalized rotation', () {
      expect(
        const GeometryState(rotationSteps: 0),
        const GeometryState(rotationSteps: 4),
      );
    });
  });

  group('PipelineReaders.geometryState', () {
    test('empty pipeline yields identity', () {
      final p = EditPipeline.forOriginal('/tmp/img.jpg');
      expect(p.geometryState, GeometryState.identity);
    });

    test('rotate op contributes steps', () {
      final p = EditPipeline.forOriginal('/tmp/img.jpg').append(
        EditOperation.create(
          type: EditOpType.rotate,
          parameters: {'steps': 3},
        ),
      );
      expect(p.geometryState.rotationStepsNormalized, 3);
    });

    test('flip op contributes h and v', () {
      final p = EditPipeline.forOriginal('/tmp/img.jpg').append(
        EditOperation.create(
          type: EditOpType.flip,
          parameters: {'h': true, 'v': false},
        ),
      );
      expect(p.geometryState.flipH, true);
      expect(p.geometryState.flipV, false);
    });

    test('straighten op contributes degrees', () {
      final p = EditPipeline.forOriginal('/tmp/img.jpg').append(
        EditOperation.create(
          type: EditOpType.straighten,
          parameters: {'value': 12.5},
        ),
      );
      expect(p.geometryState.straightenDegrees, 12.5);
    });

    test('crop op contributes aspect ratio', () {
      final p = EditPipeline.forOriginal('/tmp/img.jpg').append(
        EditOperation.create(
          type: EditOpType.crop,
          parameters: {'aspectRatio': 1.0},
        ),
      );
      expect(p.geometryState.cropAspectRatio, 1.0);
    });

    test('multiple geometry ops combine into one state', () {
      final p = EditPipeline.forOriginal('/tmp/img.jpg')
          .append(EditOperation.create(
            type: EditOpType.rotate,
            parameters: {'steps': 1},
          ))
          .append(EditOperation.create(
            type: EditOpType.flip,
            parameters: {'h': true},
          ))
          .append(EditOperation.create(
            type: EditOpType.straighten,
            parameters: {'value': -5.0},
          ));
      final g = p.geometryState;
      expect(g.rotationStepsNormalized, 1);
      expect(g.flipH, true);
      expect(g.straightenDegrees, -5.0);
      expect(g.swapsAspect, true);
    });

    test('disabled geometry ops are ignored', () {
      var p = EditPipeline.forOriginal('/tmp/img.jpg').append(
        EditOperation.create(
          type: EditOpType.rotate,
          parameters: {'steps': 2},
        ),
      );
      p = p.toggleEnabled(p.operations.first.id);
      expect(p.geometryState.rotationStepsNormalized, 0);
    });
  });

  group('activeCategories includes geometry', () {
    test('rotation 90° marks geometry as active', () {
      final p = EditPipeline.forOriginal('/tmp/img.jpg').append(
        EditOperation.create(
          type: EditOpType.rotate,
          parameters: {'steps': 1},
        ),
      );
      expect(p.activeCategories.contains(_geomCategory(p)), true);
    });
  });
}

// Tiny helper so the test doesn't need to import OpCategory directly.
Object _geomCategory(EditPipeline p) {
  final cats = p.activeCategories;
  return cats.firstWhere((c) => c.toString().contains('geometry'));
}
