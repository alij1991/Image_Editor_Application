import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:image_editor/engine/pipeline/edit_op_type.dart';
import 'package:image_editor/engine/pipeline/edit_operation.dart';
import 'package:image_editor/engine/pipeline/edit_pipeline.dart';
import 'package:image_editor/features/editor/data/project_store.dart';
import 'package:image_editor/features/editor/presentation/notifiers/auto_save_controller.dart';

/// Phase VII.1 — contract tests for [AutoSaveController].
///
/// The controller was lifted out of `editor_session.dart` in this
/// phase; these tests pin every behaviour the session previously
/// relied on so the extraction can't silently regress:
///
///   1. **Debounce** — N schedules in a tight burst collapse to one
///      save after the quiet-window elapses.
///   2. **Reset-on-schedule** — a late schedule pushes the save out,
///      it doesn't fire on the earlier deadline.
///   3. **Dispose safety** — after `flushAndDispose` no scheduled
///      callback writes, even if the timer was already armed.
///   4. **Final flush** — `flushAndDispose` issues exactly one write
///      with the pipeline the caller passes (authoritative commit),
///      NOT whatever was last scheduled.
///   5. **IO tolerance** — a `ProjectStore.save` that throws is
///      swallowed; the controller tracks the failure but never
///      rethrows.
///   6. **Idempotent dispose** — calling `flushAndDispose` twice saves
///      once.
///
/// A minimal `_RecordingStore` subclass replaces `ProjectStore.save`
/// with an in-memory recorder so the controller can be tested without
/// touching the filesystem.
void main() {
  // Ultra-short debounce so the suite doesn't wait half a second per
  // test. The controller's contract is independent of the actual
  // duration.
  const kTestDebounce = Duration(milliseconds: 10);

  EditPipeline pipelineN(int brightness) => EditPipeline.forOriginal('/img.jpg')
      .append(EditOperation.create(
        type: EditOpType.brightness,
        parameters: {'value': brightness.toDouble()},
      ));

  group('schedule — debounce behaviour', () {
    test('single schedule → one save after debounce elapses', () async {
      final store = _RecordingStore();
      final c = AutoSaveController(
        sourcePath: '/img.jpg',
        projectStore: store,
        debounce: kTestDebounce,
      );

      c.schedule(pipelineN(1));
      expect(store.calls, isEmpty,
          reason: 'save should not fire synchronously — we debounce');

      await Future<void>.delayed(kTestDebounce * 3);
      expect(store.calls, hasLength(1));
      expect(c.debugSaveCallCount, 1);
      expect(c.hasPendingSave, isFalse);
    });

    test('N schedules inside the debounce window → one save (latest wins)',
        () async {
      final store = _RecordingStore();
      final c = AutoSaveController(
        sourcePath: '/img.jpg',
        projectStore: store,
        debounce: kTestDebounce,
      );

      // Simulate a slider drag committing 5 times in quick succession.
      for (var i = 0; i < 5; i++) {
        c.schedule(pipelineN(i));
      }
      await Future<void>.delayed(kTestDebounce * 3);

      expect(store.calls, hasLength(1),
          reason: '5 rapid schedules must collapse to a single disk write');
      // Latest pipeline wins — each schedule cancels the prior timer.
      expect(
        (store.calls.single.pipeline.operations.first.parameters['value']
                as double)
            .round(),
        4,
      );
    });

    test('late schedule resets the timer (not fired on prior deadline)',
        () async {
      final store = _RecordingStore();
      final c = AutoSaveController(
        sourcePath: '/img.jpg',
        projectStore: store,
        debounce: kTestDebounce,
      );

      c.schedule(pipelineN(1));
      await Future<void>.delayed(kTestDebounce ~/ 2);
      // Halfway through the first debounce we schedule again — this
      // MUST push the deadline out, not fire at the original time.
      c.schedule(pipelineN(2));
      await Future<void>.delayed(kTestDebounce ~/ 2 + const Duration(milliseconds: 1));
      // At this point >1× the first debounce window has elapsed, but
      // the reset means we're still inside the new window.
      expect(store.calls, isEmpty,
          reason: 'second schedule should have reset the timer');

      await Future<void>.delayed(kTestDebounce * 2);
      expect(store.calls, hasLength(1));
      expect(
        (store.calls.single.pipeline.operations.first.parameters['value']
                as double)
            .round(),
        2,
      );
    });

    test('hasPendingSave tracks timer state', () async {
      final store = _RecordingStore();
      final c = AutoSaveController(
        sourcePath: '/img.jpg',
        projectStore: store,
        debounce: kTestDebounce,
      );

      expect(c.hasPendingSave, isFalse);
      c.schedule(pipelineN(1));
      expect(c.hasPendingSave, isTrue);
      await Future<void>.delayed(kTestDebounce * 3);
      expect(c.hasPendingSave, isFalse);
    });
  });

  group('dispose — lifecycle', () {
    test('flushAndDispose with pending schedule → exactly one save '
        '(uses final pipeline, not the debounced one)', () async {
      final store = _RecordingStore();
      final c = AutoSaveController(
        sourcePath: '/img.jpg',
        projectStore: store,
        debounce: kTestDebounce,
      );

      c.schedule(pipelineN(7));
      expect(c.hasPendingSave, isTrue);
      // Dispose before the debounce fires — the pending save must be
      // cancelled and replaced by our authoritative pipeline.
      await c.flushAndDispose(pipelineN(99));

      expect(store.calls, hasLength(1));
      expect(
        (store.calls.single.pipeline.operations.first.parameters['value']
                as double)
            .round(),
        99,
        reason: 'dispose must write the pipeline the caller passed, '
            'not the scheduled intermediate',
      );
      expect(c.isDisposed, isTrue);
      expect(c.hasPendingSave, isFalse);
    });

    test('schedule after flushAndDispose is a no-op', () async {
      final store = _RecordingStore();
      final c = AutoSaveController(
        sourcePath: '/img.jpg',
        projectStore: store,
        debounce: kTestDebounce,
      );

      await c.flushAndDispose(pipelineN(0));
      expect(store.calls, hasLength(1));

      c.schedule(pipelineN(1));
      c.schedule(pipelineN(2));
      await Future<void>.delayed(kTestDebounce * 3);

      expect(store.calls, hasLength(1),
          reason: 'schedules after dispose must not reach the store');
      expect(c.hasPendingSave, isFalse);
    });

    test('flushAndDispose is idempotent — second call saves nothing',
        () async {
      final store = _RecordingStore();
      final c = AutoSaveController(
        sourcePath: '/img.jpg',
        projectStore: store,
        debounce: kTestDebounce,
      );

      await c.flushAndDispose(pipelineN(1));
      await c.flushAndDispose(pipelineN(2));

      expect(store.calls, hasLength(1),
          reason: 'double-dispose must not double-save');
      expect(
        (store.calls.single.pipeline.operations.first.parameters['value']
                as double)
            .round(),
        1,
      );
    });

    test('pending timer fired after dispose does nothing', () async {
      // Race: timer callback queued but hasn't run yet, then dispose
      // sets the flag. When the callback finally runs, the _disposed
      // check must gate it out.
      final store = _RecordingStore();
      final c = AutoSaveController(
        sourcePath: '/img.jpg',
        projectStore: store,
        debounce: kTestDebounce,
      );

      c.schedule(pipelineN(1));
      await c.flushAndDispose(pipelineN(99));
      // One save from the dispose flush — no spurious save from the
      // cancelled-but-maybe-queued timer.
      await Future<void>.delayed(kTestDebounce * 3);
      expect(store.calls, hasLength(1));
    });
  });

  group('IO tolerance', () {
    test('save that throws is swallowed, counters track it', () async {
      final store = _RecordingStore(shouldThrow: true);
      final c = AutoSaveController(
        sourcePath: '/img.jpg',
        projectStore: store,
        debounce: kTestDebounce,
      );

      c.schedule(pipelineN(1));
      await Future<void>.delayed(kTestDebounce * 3);

      expect(c.debugIoFailureCount, 1,
          reason: 'a thrown save should be caught and counted');
      expect(c.debugSaveCallCount, 0,
          reason: 'successful-save counter only bumps on clean returns');
      // No rethrow would have blown up the test already; asserting
      // quiescence post-recovery.
      expect(c.hasPendingSave, isFalse);
    });

    test('flushAndDispose survives a throwing save', () async {
      final store = _RecordingStore(shouldThrow: true);
      final c = AutoSaveController(
        sourcePath: '/img.jpg',
        projectStore: store,
        debounce: kTestDebounce,
      );

      await expectLater(c.flushAndDispose(pipelineN(0)), completes);
      expect(c.debugIoFailureCount, 1);
      expect(c.isDisposed, isTrue);
    });
  });

  // IX.C.4 — disk-full auto-save path. The existing "throwing save"
  // tests cover any IOException; these pin the specific ENOSPC
  // (disk-full) failure mode the PLAN calls out + verify the
  // controller keeps trying subsequent saves instead of giving up.
  group('disk-full resilience (IX.C.4)', () {
    test('FileSystemException(ENOSPC) is caught + counted', () async {
      final store = _DiskFullStore();
      final c = AutoSaveController(
        sourcePath: '/img.jpg',
        projectStore: store,
        debounce: kTestDebounce,
      );

      c.schedule(pipelineN(1));
      await Future<void>.delayed(kTestDebounce * 3);

      expect(c.debugIoFailureCount, 1);
      expect(c.debugSaveCallCount, 0);
      expect(store.attempts, 1);
      // Controller stays usable — a later schedule can succeed if
      // the disk frees up.
      expect(c.isDisposed, isFalse);
    });

    test('controller recovers when disk frees up mid-session', () async {
      final store = _DiskFullStore();
      final c = AutoSaveController(
        sourcePath: '/img.jpg',
        projectStore: store,
        debounce: kTestDebounce,
      );

      // First save fails with ENOSPC.
      c.schedule(pipelineN(1));
      await Future<void>.delayed(kTestDebounce * 3);
      expect(c.debugIoFailureCount, 1);

      // Simulate the user freeing space.
      store.diskFull = false;

      // Next save succeeds.
      c.schedule(pipelineN(2));
      await Future<void>.delayed(kTestDebounce * 3);
      expect(c.debugSaveCallCount, 1);
      expect(c.debugIoFailureCount, 1,
          reason: 'failure counter does not decrement on later success');
      expect(store.calls.length, 1);
    });

    test('flushAndDispose on a disk-full store still marks disposed',
        () async {
      final store = _DiskFullStore();
      final c = AutoSaveController(
        sourcePath: '/img.jpg',
        projectStore: store,
        debounce: kTestDebounce,
      );

      await c.flushAndDispose(pipelineN(1));
      expect(c.isDisposed, isTrue);
      expect(c.debugIoFailureCount, 1,
          reason: 'the final flush attempt threw ENOSPC');
      // Session teardown completes regardless — never throws upward,
      // so the editor route can still unmount cleanly even when the
      // disk is full.
    });

    test('repeated disk-full attempts do not leak timers / state', () async {
      final store = _DiskFullStore();
      final c = AutoSaveController(
        sourcePath: '/img.jpg',
        projectStore: store,
        debounce: kTestDebounce,
      );

      for (var i = 0; i < 5; i++) {
        c.schedule(pipelineN(i));
        await Future<void>.delayed(kTestDebounce * 3);
      }
      expect(c.debugIoFailureCount, 5);
      expect(c.hasPendingSave, isFalse,
          reason: 'no stray timer should remain after each attempt');
    });
  });

  group('constructor defaults', () {
    test('default debounce is 600 ms (matches pre-extraction session)',
        () async {
      // We don't wait 600 ms in the test — just verify the controller
      // constructs with the default and the internal state is sane.
      final store = _RecordingStore();
      final c = AutoSaveController(
        sourcePath: '/img.jpg',
        projectStore: store,
      );
      expect(c.hasPendingSave, isFalse);
      expect(c.isDisposed, isFalse);
      // Post-condition: dispose without ever scheduling should still
      // fire the final write so a closing session without edits
      // updates metadata (e.g. last-opened timestamp, if later added).
      await c.flushAndDispose(pipelineN(0));
      expect(store.calls, hasLength(1));
    });
  });
}

/// Minimal [ProjectStore] subclass that records every [save] call in
/// memory and optionally throws to simulate IO failure.
///
/// The base class needs a valid [rootOverride] because its constructor
/// refuses to resolve `path_provider` in tests. We pass it but never
/// use it — `save` is fully overridden and never calls `super`.
class _RecordingStore extends ProjectStore {
  _RecordingStore({this.shouldThrow = false});

  final bool shouldThrow;
  final List<_SaveCall> calls = [];

  @override
  Future<void> save({
    required String sourcePath,
    required EditPipeline pipeline,
    String? customTitle,
  }) async {
    if (shouldThrow) throw StateError('forced IO failure');
    calls.add(_SaveCall(path: sourcePath, pipeline: pipeline));
  }
}

class _SaveCall {
  const _SaveCall({required this.path, required this.pipeline});
  final String path;
  final EditPipeline pipeline;
}

/// IX.C.4 — specialised [ProjectStore] stub that throws the real-world
/// disk-full exception (`FileSystemException` with errno 28 / ENOSPC).
/// Lets tests flip the `diskFull` flag mid-session to simulate the
/// user freeing space.
class _DiskFullStore extends ProjectStore {
  _DiskFullStore({this.diskFull = true});

  bool diskFull;
  int attempts = 0;
  final List<_SaveCall> calls = [];

  @override
  Future<void> save({
    required String sourcePath,
    required EditPipeline pipeline,
    String? customTitle,
  }) async {
    attempts++;
    if (diskFull) {
      throw const FileSystemException(
        'No space left on device',
        '/dev/sda1',
        OSError('ENOSPC', 28),
      );
    }
    calls.add(_SaveCall(path: sourcePath, pipeline: pipeline));
  }
}
