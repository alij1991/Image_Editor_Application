import 'package:flutter_test/flutter_test.dart';

import 'package:image_editor/engine/pipeline/edit_pipeline.dart';
import 'package:image_editor/features/editor/presentation/notifiers/preview_controller.dart';

void main() {
  group('PreviewController', () {
    test('setPasses notifies listeners when value changes', () {
      var calls = 0;
      final c = PreviewController(onCommit: (_) {});
      c.passes.addListener(() => calls++);
      // Distinct lists so ValueNotifier detects a change each time.
      c.setPasses([]);
      c.setPasses([]);
      c.setPasses([]);
      expect(calls, 3);
      c.dispose();
    });

    test('scheduleCommit debounces multiple calls', () async {
      var commits = 0;
      final c = PreviewController(
        onCommit: (_) => commits++,
        commitDebounce: const Duration(milliseconds: 20),
      );
      for (int i = 0; i < 5; i++) {
        c.scheduleCommit(EditPipeline.forOriginal('/tmp/img.jpg'));
      }
      await Future<void>.delayed(const Duration(milliseconds: 60));
      expect(commits, 1,
          reason: 'five rapid schedules should coalesce into one commit');
      c.dispose();
    });

    test('flushCommit fires pending commit immediately', () async {
      var commits = 0;
      final c = PreviewController(
        onCommit: (_) => commits++,
        commitDebounce: const Duration(milliseconds: 500),
      );
      c.scheduleCommit(EditPipeline.forOriginal('/tmp/img.jpg'));
      c.flushCommit();
      expect(commits, 1);
      c.dispose();
    });

    test('flushCommit without pending is a no-op', () {
      var commits = 0;
      final c = PreviewController(onCommit: (_) => commits++);
      c.flushCommit();
      expect(commits, 0);
      c.dispose();
    });
  });
}
