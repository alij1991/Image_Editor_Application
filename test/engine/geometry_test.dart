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

  group('CropRect', () {
    test('full is the no-crop sentinel', () {
      expect(CropRect.full.isFull, true);
      expect(CropRect.full.width, 1);
      expect(CropRect.full.height, 1);
    });

    test('isFull tolerates tiny float drift', () {
      const tiny = CropRect(
        left: 0.00001,
        top: 0.0,
        right: 1.0,
        bottom: 0.99999,
      );
      expect(tiny.isFull, true);
    });

    test('width/height compute from edges', () {
      const r = CropRect(left: 0.2, top: 0.1, right: 0.8, bottom: 0.6);
      expect(r.width, closeTo(0.6, 1e-9));
      expect(r.height, closeTo(0.5, 1e-9));
    });

    test('toRect projects into source-pixel coordinates', () {
      const r = CropRect(left: 0.25, top: 0.5, right: 0.75, bottom: 1.0);
      final pixel = r.toRect(800, 600);
      expect(pixel.left, 200);
      expect(pixel.top, 300);
      expect(pixel.right, 600);
      expect(pixel.bottom, 600);
    });

    test('normalized clamps and orders edges', () {
      const swapped = CropRect(
        left: 0.7,
        top: 0.9,
        right: 0.2,
        bottom: 0.1,
      );
      final norm = swapped.normalized();
      expect(norm.left, lessThan(norm.right));
      expect(norm.top, lessThan(norm.bottom));

      const overflow = CropRect(left: -0.1, top: 0.0, right: 1.5, bottom: 1.2);
      final clamped = overflow.normalized();
      expect(clamped.left, 0);
      expect(clamped.right, 1);
      expect(clamped.bottom, 1);
    });

    test('toParams / fromParams round-trips every edge', () {
      const r = CropRect(left: 0.1, top: 0.2, right: 0.8, bottom: 0.9);
      final back = CropRect.fromParams(r.toParams());
      expect(back, equals(r));
    });

    test('fromParams returns null when an edge is missing', () {
      expect(CropRect.fromParams(<String, dynamic>{}), isNull);
      expect(
        CropRect.fromParams(<String, dynamic>{'left': 0.1, 'top': 0.2}),
        isNull,
      );
    });

    test('equality is value-based', () {
      const a = CropRect(left: 0.1, top: 0.2, right: 0.8, bottom: 0.9);
      const b = CropRect(left: 0.1, top: 0.2, right: 0.8, bottom: 0.9);
      const c = CropRect(left: 0, top: 0, right: 1, bottom: 1);
      expect(a, equals(b));
      expect(a, isNot(equals(c)));
    });
  });

  group('GeometryState cropRect integration', () {
    test('default cropRect is null and effectiveCropRect is full', () {
      const g = GeometryState();
      expect(g.cropRect, isNull);
      expect(g.effectiveCropRect, equals(CropRect.full));
      expect(g.hasCrop, false);
      expect(g.isIdentity, true);
    });

    test('hasCrop is false for the full rect', () {
      const g = GeometryState(cropRect: CropRect.full);
      expect(g.hasCrop, false);
      expect(g.isIdentity, true);
    });

    test('hasCrop is true for any non-full rect', () {
      const g = GeometryState(
        cropRect: CropRect(left: 0.1, top: 0.1, right: 0.9, bottom: 0.9),
      );
      expect(g.hasCrop, true);
      expect(g.isIdentity, false);
    });

    test('copyWith updates cropRect (sentinel pattern)', () {
      const g = GeometryState();
      const r = CropRect(left: 0.2, top: 0.2, right: 0.8, bottom: 0.8);
      final next = g.copyWith(cropRect: r);
      expect(next.cropRect, equals(r));
      // Calling copyWith without cropRect must preserve it.
      final later = next.copyWith(flipH: true);
      expect(later.cropRect, equals(r));
      // Explicit null clears it.
      final cleared = next.copyWith(cropRect: null);
      expect(cleared.cropRect, isNull);
    });

    test('pipeline op with crop edges produces a cropRect', () {
      final p = EditPipeline.forOriginal('/tmp/img.jpg').append(
        EditOperation.create(
          type: EditOpType.crop,
          parameters: {
            'left': 0.1,
            'top': 0.2,
            'right': 0.9,
            'bottom': 0.8,
          },
        ),
      );
      final geom = p.geometryState;
      expect(geom.cropRect, isNotNull);
      expect(geom.cropRect!.width, closeTo(0.8, 1e-9));
      expect(geom.cropRect!.height, closeTo(0.6, 1e-9));
    });

    test('pipeline op with only aspectRatio leaves cropRect null', () {
      final p = EditPipeline.forOriginal('/tmp/img.jpg').append(
        EditOperation.create(
          type: EditOpType.crop,
          parameters: {'aspectRatio': 1.5},
        ),
      );
      final geom = p.geometryState;
      expect(geom.cropRect, isNull);
      expect(geom.cropAspectRatio, 1.5);
    });
  });
}

// Tiny helper so the test doesn't need to import OpCategory directly.
Object _geomCategory(EditPipeline p) {
  final cats = p.activeCategories;
  return cats.firstWhere((c) => c.toString().contains('geometry'));
}
