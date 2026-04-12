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
