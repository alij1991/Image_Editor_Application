import 'package:flutter_test/flutter_test.dart';

import 'package:image_editor/engine/pipeline/edit_op_type.dart';
import 'package:image_editor/engine/pipeline/edit_operation.dart';
import 'package:image_editor/engine/pipeline/edit_pipeline.dart';
import 'package:image_editor/engine/pipeline/tone_curve_set.dart';
import 'package:image_editor/features/editor/presentation/notifiers/render_driver.dart';

/// Phase VII.3 — contract tests for [RenderDriver].
///
/// Three surface areas + their invariants:
///
///   1. **`passesFor`** — empty pipeline short-circuits; a pipeline
///      with enabled matrix ops produces a non-empty pass list routed
///      through `editorPassBuilders`. Repeat calls return fresh lists
///      without spinning up async resources.
///
///   2. **`bakeCurveLut` coalescing** (the Phase V.6 perf invariant,
///      preserved post-VII.3) — a burst of N requests while one bake
///      is in flight produces at most 2 isolate spawns (one in flight
///      + one queued). Tested without waiting for the `compute()`
///      isolate to actually return so the assertion is sync and fast.
///
///   3. **`clearCurveLutCache` / `dispose`** — the drop-everything
///      paths. dispose is idempotent, post-dispose bakes are no-ops,
///      `debugHasPendingBake` flips correctly across each transition.
///
/// The driver's shader-pass ordering inherits from
/// `editorPassBuilders`, which has its own dedicated test
/// (`passes_for_test.dart`). This file only proves the wrapper
/// routes correctly, not the order.
void main() {
  EditOperation op(String type, [Map<String, dynamic> params = const {}]) =>
      EditOperation.create(type: type, parameters: params);

  // Simple curve set — two channels so the bake has work to do without
  // being trivial identity.
  ToneCurveSet curve() => const ToneCurveSet(
        master: [
          [0.0, 0.0],
          [0.5, 0.6],
          [1.0, 1.0],
        ],
      );

  group('passesFor', () {
    test('empty pipeline → const empty list', () {
      final driver = RenderDriver(
        onRebuildPreview: () {},
        isSessionDisposed: () => false,
      );
      final empty = EditPipeline.forOriginal('/img.jpg');
      expect(driver.passesFor(empty), isEmpty);
      driver.dispose();
    });

    test('pipeline with an enabled matrix op → non-empty pass list '
        '(routes through editorPassBuilders)', () {
      final driver = RenderDriver(
        onRebuildPreview: () {},
        isSessionDisposed: () => false,
      );
      final pipeline = EditPipeline.forOriginal('/img.jpg').append(
        op(EditOpType.brightness, {'value': 0.3}),
      );
      final passes = driver.passesFor(pipeline);
      expect(passes, isNotEmpty,
          reason: 'brightness op must produce at least one shader pass');
      driver.dispose();
    });

    test('repeated passesFor calls on the same pipeline return equal '
        'lengths (matrixScratch reuse is not destructive)', () {
      final driver = RenderDriver(
        onRebuildPreview: () {},
        isSessionDisposed: () => false,
      );
      final pipeline = EditPipeline.forOriginal('/img.jpg').append(
        op(EditOpType.brightness, {'value': 0.5}),
      );
      final a = driver.passesFor(pipeline);
      final b = driver.passesFor(pipeline);
      expect(a.length, b.length);
      expect(a.length, greaterThan(0));
      driver.dispose();
    });
  });

  group('bakeCurveLut — coalescing invariant', () {
    test('first bake flips loading + bumps counter + records key', () {
      final driver = RenderDriver(
        onRebuildPreview: () {},
        isSessionDisposed: () => false,
      );
      expect(driver.debugCurveLutLoading, isFalse);
      expect(driver.debugCurveBakeIsolateLaunches, 0);

      driver.bakeCurveLut('k1', curve());

      expect(driver.debugCurveLutLoading, isTrue,
          reason: 'loading flag flips sync on the bake kickoff');
      expect(driver.debugCurveBakeIsolateLaunches, 1);
      expect(driver.debugCurveLutKey, 'k1');
      expect(driver.debugHasPendingBake, isFalse,
          reason: 'no pending queue entry while the first bake is in flight');

      driver.dispose();
    });

    test('60-frame drag collapses to 1 in-flight + 1 pending '
        '(not 60 spawns)', () {
      final driver = RenderDriver(
        onRebuildPreview: () {},
        isSessionDisposed: () => false,
      );
      // Simulate a 60-frame drag: one initial bake + 59 updates while
      // it's still in flight. The coalescer must park every update in
      // the single pending slot — only the latest survives.
      driver.bakeCurveLut('k0', curve());
      for (var i = 1; i < 60; i++) {
        driver.bakeCurveLut('k$i', curve());
      }

      expect(driver.debugCurveBakeIsolateLaunches, 1,
          reason: 'the first bake is still in flight; the 59 follow-ups '
              'must coalesce in the pending slot and NOT spawn isolates');
      expect(driver.debugHasPendingBake, isTrue,
          reason: 'the latest request parks in the pending slot');
      expect(driver.debugCurveLutKey, 'k0',
          reason: 'the in-flight bake still owns the key until it lands');

      driver.dispose();
    });

    test('pending slot is single-entry — second update overwrites the '
        'first without affecting the counter', () {
      final driver = RenderDriver(
        onRebuildPreview: () {},
        isSessionDisposed: () => false,
      );
      driver.bakeCurveLut('k-in-flight', curve());
      expect(driver.debugCurveBakeIsolateLaunches, 1);

      driver.bakeCurveLut('k-queued-A', curve());
      expect(driver.debugHasPendingBake, isTrue);
      expect(driver.debugCurveBakeIsolateLaunches, 1,
          reason: 'queueing must not count as an isolate spawn');

      driver.bakeCurveLut('k-queued-B', curve());
      expect(driver.debugHasPendingBake, isTrue,
          reason: 'still exactly one pending slot after the overwrite');
      expect(driver.debugCurveBakeIsolateLaunches, 1,
          reason: 'overwrite also must not count as an isolate spawn');

      driver.dispose();
    });
  });

  group('clearCurveLutCache', () {
    test('resets key when no image was cached', () {
      final driver = RenderDriver(
        onRebuildPreview: () {},
        isSessionDisposed: () => false,
      );
      driver.bakeCurveLut('k1', curve());
      // Mid-bake: key set, but image not yet populated.
      expect(driver.debugCurveLutKey, 'k1');
      expect(driver.debugCurveLutImage, isNull);

      driver.clearCurveLutCache();

      expect(driver.debugCurveLutKey, isNull);
      expect(driver.debugCurveLutImage, isNull);

      driver.dispose();
    });
  });

  group('dispose lifecycle', () {
    test('dispose flips isDisposed and clears pending slot', () {
      final driver = RenderDriver(
        onRebuildPreview: () {},
        isSessionDisposed: () => false,
      );
      driver.bakeCurveLut('k0', curve());
      driver.bakeCurveLut('k1', curve());
      expect(driver.debugHasPendingBake, isTrue);

      driver.dispose();

      expect(driver.debugDisposed, isTrue);
      expect(driver.debugHasPendingBake, isFalse,
          reason: 'dispose must drop the pending slot so no late bake '
              'fires into a torn-down session');
      expect(driver.debugCurveLutKey, isNull);
    });

    test('dispose is idempotent — calling twice is safe', () {
      final driver = RenderDriver(
        onRebuildPreview: () {},
        isSessionDisposed: () => false,
      );
      driver.dispose();
      // Would throw in debug builds if the driver tried to re-dispose
      // an already-disposed ui.Image.
      driver.dispose();
      expect(driver.debugDisposed, isTrue);
    });

    test('bakeCurveLut after dispose is a no-op (counter stays put)', () {
      final driver = RenderDriver(
        onRebuildPreview: () {},
        isSessionDisposed: () => false,
      );
      driver.dispose();
      driver.bakeCurveLut('k-after-dispose', curve());
      expect(driver.debugCurveBakeIsolateLaunches, 0);
      expect(driver.debugCurveLutLoading, isFalse);
    });

    test('passesFor after dispose still returns a valid list (empty '
        'pipeline short-circuit + non-disposing code path intact)', () {
      final driver = RenderDriver(
        onRebuildPreview: () {},
        isSessionDisposed: () => true,
      );
      driver.dispose();
      expect(
        driver.passesFor(EditPipeline.forOriginal('/img.jpg')),
        isEmpty,
      );
    });
  });
}
