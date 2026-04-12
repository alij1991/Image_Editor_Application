import 'package:flutter_test/flutter_test.dart';

import 'package:image_editor/engine/pipeline/edit_op_type.dart';
import 'package:image_editor/engine/pipeline/edit_operation.dart';
import 'package:image_editor/engine/pipeline/edit_pipeline.dart';
import 'package:image_editor/engine/pipeline/pipeline_extensions.dart';
import 'package:image_editor/features/editor/presentation/notifiers/preview_controller.dart';

/// EditorSession is integration-tested on device (it touches dart:ui via
/// the preview proxy + path_provider for mementos). Here we unit-test the
/// two isolated pieces the session depends on: the pipeline extension
/// readers that the SliderRow uses for its thumb position, and the
/// PreviewController commit flow that drives the debounced history push.
void main() {
  EditOperation brightness(double v) => EditOperation.create(
        type: EditOpType.brightness,
        parameters: {'value': v},
      );

  group('PipelineReaders', () {
    test('brightnessValue returns 0 when pipeline is empty', () {
      final p = EditPipeline.forOriginal('/tmp/img.jpg');
      expect(p.brightnessValue, 0.0);
    });

    test('brightnessValue returns current brightness op value', () {
      final p =
          EditPipeline.forOriginal('/tmp/img.jpg').append(brightness(0.42));
      expect(p.brightnessValue, 0.42);
    });

    test('disabled brightness op reads as 0 (identity)', () {
      var p =
          EditPipeline.forOriginal('/tmp/img.jpg').append(brightness(0.3));
      expect(p.brightnessValue, 0.3);
      p = p.toggleEnabled(p.operations.first.id);
      expect(p.brightnessValue, 0.0,
          reason: 'disabled ops should read as identity');
    });

    test('multiple brightness ops read the first enabled one', () {
      final p = EditPipeline.forOriginal('/tmp/img.jpg')
          .append(brightness(0.1))
          .append(brightness(0.5));
      expect(p.brightnessValue, 0.1);
    });

    test('other op types do not affect brightness reader', () {
      final p = EditPipeline.forOriginal('/tmp/img.jpg').append(
        EditOperation.create(
          type: EditOpType.contrast,
          parameters: {'value': 0.9},
        ),
      );
      expect(p.brightnessValue, 0.0);
    });
  });

  group('PreviewController commit flow', () {
    test('commit callback receives the exact pipeline scheduled', () async {
      EditPipeline? received;
      final c = PreviewController(
        onCommit: (p) => received = p,
        commitDebounce: const Duration(milliseconds: 5),
      );
      final expected =
          EditPipeline.forOriginal('/tmp/a.jpg').append(brightness(0.7));
      c.scheduleCommit(expected);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(received, same(expected));
      c.dispose();
    });

    test('subsequent schedules replace the pending pipeline', () async {
      EditPipeline? received;
      final c = PreviewController(
        onCommit: (p) => received = p,
        commitDebounce: const Duration(milliseconds: 20),
      );
      final first =
          EditPipeline.forOriginal('/tmp/a.jpg').append(brightness(0.1));
      final second =
          EditPipeline.forOriginal('/tmp/a.jpg').append(brightness(0.9));
      c.scheduleCommit(first);
      c.scheduleCommit(second);
      await Future<void>.delayed(const Duration(milliseconds: 60));
      expect(received, same(second),
          reason: 'latest schedule wins after debounce');
      c.dispose();
    });
  });
}
