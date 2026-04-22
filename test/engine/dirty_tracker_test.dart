import 'package:flutter_test/flutter_test.dart';

import 'package:image_editor/engine/pipeline/dirty_tracker.dart';
import 'package:image_editor/engine/pipeline/edit_op_type.dart';
import 'package:image_editor/engine/pipeline/edit_operation.dart';
import 'package:image_editor/engine/pipeline/edit_pipeline.dart';

void main() {
  group('DirtyTracker', () {
    test('empty pipeline yields dirty index 0', () {
      final tracker = DirtyTracker();
      tracker.notifyPipelineChanged(EditPipeline.forOriginal('/tmp/img.jpg'));
      expect(tracker.firstDirtyIndex, 0);
    });

    test('identical pipeline yields dirty at end (nothing changed)', () {
      final tracker = DirtyTracker();
      final op = EditOperation.create(
        type: EditOpType.brightness,
        parameters: {'value': 0.1},
      );
      final pipeline = EditPipeline.forOriginal('/tmp/img.jpg').append(op);
      tracker.notifyPipelineChanged(pipeline);
      tracker.notifyPipelineChanged(pipeline);
      expect(tracker.firstDirtyIndex, 1);
    });

    test('changing an op parameter dirties at that index', () {
      final tracker = DirtyTracker();
      final op1 = EditOperation.create(
        type: EditOpType.brightness,
        parameters: {'value': 0.1},
      );
      final op2 = EditOperation.create(
        type: EditOpType.contrast,
        parameters: {'value': 0.2},
      );
      var pipeline = EditPipeline.forOriginal('/tmp/img.jpg')
          .append(op1)
          .append(op2);
      tracker.notifyPipelineChanged(pipeline);
      expect(tracker.firstDirtyIndex, 0);

      pipeline = pipeline.replace(op2.copyWith(parameters: {'value': 0.5}));
      tracker.notifyPipelineChanged(pipeline);
      expect(tracker.firstDirtyIndex, 1,
          reason: 'op2 changed so index 1 is dirty');
    });

    test('toggling enabled flag on early op dirties early', () {
      final tracker = DirtyTracker();
      final op1 = EditOperation.create(
        type: EditOpType.brightness,
        parameters: {'value': 0.1},
      );
      final op2 = EditOperation.create(
        type: EditOpType.contrast,
        parameters: {'value': 0.2},
      );
      var pipeline = EditPipeline.forOriginal('/tmp/img.jpg')
          .append(op1)
          .append(op2);
      tracker.notifyPipelineChanged(pipeline);
      pipeline = pipeline.toggleEnabled(op1.id);
      tracker.notifyPipelineChanged(pipeline);
      expect(tracker.firstDirtyIndex, 0);
    });

    test('HSL op with structurally-equal List params does not re-dirty', () {
      // Regression for Phase XI.A.2: shallow _mapEquals saw two
      // freshly-built `[0.1, 0.0, ...]` lists as unequal, forcing a
      // false dirty when an upstream op (e.g. preset apply) rebuilt the
      // entire ops list without touching HSL values.
      final tracker = DirtyTracker();
      final hsl = EditOperation.create(
        type: EditOpType.hsl,
        parameters: {
          'hue': [0.1, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0],
          'sat': [0.2, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0],
          'lum': List<double>.filled(8, 0.0),
        },
      );
      final tail = EditOperation.create(
        type: EditOpType.contrast,
        parameters: {'value': 0.3},
      );
      var pipeline = EditPipeline.forOriginal('/tmp/img.jpg')
          .append(hsl)
          .append(tail);
      tracker.notifyPipelineChanged(pipeline);

      // Rebuild HSL with the SAME logical params but fresh lists (simulates
      // a pipeline reconstruction that preserves shape but not references).
      final hslRebuilt = hsl.copyWith(parameters: {
        'hue': [0.1, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0],
        'sat': [0.2, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0],
        'lum': List<double>.filled(8, 0.0),
      });
      pipeline = pipeline.replace(hslRebuilt);
      tracker.notifyPipelineChanged(pipeline);
      expect(tracker.firstDirtyIndex, 2,
          reason: 'HSL rebuild with equal contents must not re-dirty');
    });

    test('HSL op detects a single list-element change', () {
      final tracker = DirtyTracker();
      final hsl = EditOperation.create(
        type: EditOpType.hsl,
        parameters: {
          'hue': [0.1, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0],
        },
      );
      var pipeline = EditPipeline.forOriginal('/tmp/img.jpg').append(hsl);
      tracker.notifyPipelineChanged(pipeline);

      pipeline = pipeline.replace(hsl.copyWith(parameters: {
        'hue': [0.1, 0.0, 0.5, 0.0, 0.0, 0.0, 0.0, 0.0], // index 2 changed
      }));
      tracker.notifyPipelineChanged(pipeline);
      expect(tracker.firstDirtyIndex, 0);
    });

    test('split-toning List<double> unchanged does not re-dirty', () {
      final tracker = DirtyTracker();
      final split = EditOperation.create(
        type: EditOpType.splitToning,
        parameters: {
          'hiColor': [0.95, 0.65, 0.35],
          'loColor': [0.25, 0.55, 0.75],
          'balance': 0.0,
        },
      );
      var pipeline = EditPipeline.forOriginal('/tmp/img.jpg').append(split);
      tracker.notifyPipelineChanged(pipeline);

      pipeline = pipeline.replace(split.copyWith(parameters: {
        'hiColor': [0.95, 0.65, 0.35],
        'loColor': [0.25, 0.55, 0.75],
        'balance': 0.0,
      }));
      tracker.notifyPipelineChanged(pipeline);
      expect(tracker.firstDirtyIndex, 1);
    });

    test('tone-curve nested List<List<double>> equality', () {
      final tracker = DirtyTracker();
      final curve = EditOperation.create(
        type: EditOpType.toneCurve,
        parameters: {
          'master': [
            [0.0, 0.0],
            [0.5, 0.6],
            [1.0, 1.0],
          ],
        },
      );
      var pipeline = EditPipeline.forOriginal('/tmp/img.jpg').append(curve);
      tracker.notifyPipelineChanged(pipeline);

      pipeline = pipeline.replace(curve.copyWith(parameters: {
        'master': [
          [0.0, 0.0],
          [0.5, 0.6],
          [1.0, 1.0],
        ],
      }));
      tracker.notifyPipelineChanged(pipeline);
      expect(tracker.firstDirtyIndex, 1, reason: 'nested-list deep equal');

      pipeline = pipeline.replace(curve.copyWith(parameters: {
        'master': [
          [0.0, 0.0],
          [0.5, 0.7], // changed
          [1.0, 1.0],
        ],
      }));
      tracker.notifyPipelineChanged(pipeline);
      expect(tracker.firstDirtyIndex, 0, reason: 'nested-list diff detected');
    });

    test('invalidateAll clears cursor and cache', () {
      final tracker = DirtyTracker();
      final op = EditOperation.create(
        type: EditOpType.brightness,
        parameters: {'value': 0.1},
      );
      tracker.notifyPipelineChanged(
        EditPipeline.forOriginal('/tmp/img.jpg').append(op),
      );
      tracker.invalidateAll();
      expect(tracker.firstDirtyIndex, 0);
      expect(tracker.cacheSize, 0);
    });
  });
}
