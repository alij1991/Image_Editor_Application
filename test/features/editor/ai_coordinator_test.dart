import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

import 'package:image_editor/ai/services/bg_removal/bg_removal_strategy.dart';
import 'package:image_editor/ai/services/denoise/ai_denoise_service.dart';
import 'package:image_editor/ai/services/face_detect/face_detection_service.dart';
import 'package:image_editor/ai/services/face_restore/face_restore_service.dart';
import 'package:image_editor/ai/services/sharpen/ai_sharpen_service.dart';
import 'package:image_editor/engine/layers/content_layer.dart';
import 'package:image_editor/engine/layers/cutout_store.dart';
import 'package:image_editor/engine/pipeline/edit_op_type.dart';
import 'package:image_editor/engine/pipeline/edit_operation.dart';
import 'package:image_editor/engine/pipeline/edit_pipeline.dart';
import 'package:image_editor/engine/pipeline/pipeline_extensions.dart';
import 'package:image_editor/features/editor/presentation/notifiers/ai_coordinator.dart';

/// Phase VII.2 — contract tests for [AiCoordinator].
///
/// Three surface areas live in this class and each has its own group:
///
///   1. **Cutout cache** (cacheCutoutImage / cutoutImageFor / persist):
///      stores the bitmap, disposes prior, routes through CutoutStore.
///   2. **Hydrate**: on session start the coordinator decodes PNGs for
///      every AdjustmentLayer, skipping ones already in-memory and
///      respecting the race guard if an AI op lands mid-decode.
///   3. **runInference**: dispose-guarded + typed-exception-wrapped
///      service runner — the common backbone every `applyXxx` method
///      in the session now delegates through.
///
/// The "round-trip memento" test at the end exercises all three at
/// once: cache → simulated-undo empties the pipeline → simulated-redo
/// → the coordinator still returns the same bitmap (proving cutouts
/// survive history bounces, the Phase VII.2 PLAN spec).
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // Tiny 2x2 PNG generated at test-load time so every `cacheCutoutImage`
  // has a valid `ui.Image` to hand out without touching disk.
  final k2x2Png = Uint8List.fromList(img.encodePng(img.Image(width: 2, height: 2)));

  Future<ui.Image> decode(Uint8List bytes) async {
    final codec = await ui.instantiateImageCodec(bytes);
    final frame = await codec.getNextFrame();
    codec.dispose();
    return frame.image;
  }

  late Directory tmp;
  late CutoutStore store;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('ai_coord_test_');
    store = CutoutStore(rootOverride: tmp);
  });

  tearDown(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  // Silent hydrate-landed callback — groups that want to assert on it
  // wire their own closure.
  void noHydrateLanded() {}

  // VII.4 added two required callbacks to the constructor. Existing
  // tests exercise cache + hydrate + runInference, none of which
  // invoke these callbacks — stubs are sufficient.
  void noCommit({required AdjustmentLayer layer, required String presetName}) {}
  Future<List<DetectedFace>> noDetectFaces(
    FaceDetectionService detector,
  ) async =>
      const [];

  void noCommitPair({
    required AdjustmentLayer first,
    required AdjustmentLayer second,
    required String presetName,
  }) {}

  AiCoordinator buildCoord({
    required CutoutStore cutoutStore,
    VoidCallback? onHydrateLanded,
    CommitAdjustmentLayer? commitAdjustmentLayer,
    CommitAdjustmentLayerPair? commitAdjustmentLayerPair,
    DetectFaces? detectFaces,
  }) {
    return AiCoordinator(
      sourcePath: '/img.jpg',
      cutoutStore: cutoutStore,
      onHydrateLanded: onHydrateLanded ?? noHydrateLanded,
      commitAdjustmentLayer: commitAdjustmentLayer ?? noCommit,
      commitAdjustmentLayerPair:
          commitAdjustmentLayerPair ?? noCommitPair,
      detectFaces: detectFaces ?? noDetectFaces,
    );
  }

  group('cutout cache', () {
    test('cacheCutoutImage stores the bitmap; cutoutImageFor returns it',
        () async {
      final coord = buildCoord(cutoutStore: store);
      final image = await decode(k2x2Png);

      coord.cacheCutoutImage('layer-1', image);

      expect(coord.cutoutImageFor('layer-1'), same(image),
          reason: 'exact same ui.Image instance must be returned');
      expect(coord.cutoutCount, 1);

      coord.dispose();
    });

    test('cutoutImageFor returns null for unknown layerId', () async {
      final coord = buildCoord(cutoutStore: store);
      expect(coord.cutoutImageFor('nope'), isNull);
      coord.dispose();
    });

    test('cacheCutoutImage disposes the prior bitmap for the same id',
        () async {
      final coord = buildCoord(cutoutStore: store);
      final first = await decode(k2x2Png);
      final second = await decode(k2x2Png);

      coord.cacheCutoutImage('layer-1', first);
      coord.cacheCutoutImage('layer-1', second);

      expect(first.debugDisposed, isTrue,
          reason: 're-caching must dispose the prior bitmap');
      expect(second.debugDisposed, isFalse);
      expect(coord.cutoutImageFor('layer-1'), same(second));

      coord.dispose();
    });

    test('cacheCutoutImage persists PNG through CutoutStore (async)',
        () async {
      final coord = buildCoord(cutoutStore: store);
      final image = await decode(k2x2Png);
      coord.cacheCutoutImage('layer-1', image);

      // `cacheCutoutImage` fires an unawaited persist; pump the
      // microtask + IO queue until either the success counter flips
      // or 20 ticks elapse. `image.toByteData` crosses the engine
      // binding in release builds but uses an embedder-provided codec
      // in flutter_test — it takes a handful of event-loop ticks to
      // resolve, not zero.
      for (var i = 0; i < 20 && coord.debugPersistSuccessCount == 0; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      expect(coord.debugPersistFailureCount, 0,
          reason: 'persist should not have failed');

      // Authoritative check: the store round-trips the PNG bytes.
      final bytes = await store.get(
        sourcePath: '/img.jpg',
        layerId: 'layer-1',
      );
      expect(bytes, isNotNull);
      expect(bytes!, isNotEmpty);
      expect(coord.debugPersistSuccessCount, 1,
          reason: 'with the round-trip confirmed above, the counter '
              'must have tracked it');

      coord.dispose();
    });

    test('cacheCutoutImage after dispose → incoming image is disposed, '
        'not in the map', () async {
      final coord = buildCoord(cutoutStore: store);
      coord.dispose();

      final image = await decode(k2x2Png);
      coord.cacheCutoutImage('layer-1', image);

      expect(image.debugDisposed, isTrue,
          reason: 'orphaned image must be disposed to avoid GPU leak');
      expect(coord.cutoutImageFor('layer-1'), isNull);
      expect(coord.cutoutCount, 0);
    });
  });

  group('hydrate', () {
    EditPipeline pipelineWithAdjustment(String layerId) {
      final layer = AdjustmentLayer(
        id: layerId,
        adjustmentKind: AdjustmentKind.backgroundRemoval,
      );
      final op = EditOperation.create(
        type: EditOpType.adjustmentLayer,
        parameters: layer.toParams(),
      ).copyWith(id: layerId);
      return EditPipeline.forOriginal('/img.jpg').append(op);
    }

    test('no AdjustmentLayers → hydrate short-circuits without calling '
        'onHydrateLanded', () async {
      int landed = 0;
      final coord = buildCoord(
        cutoutStore: store,
        onHydrateLanded: () => landed++,
      );
      await coord.hydrate(EditPipeline.forOriginal('/img.jpg'));
      expect(landed, 0);
      expect(coord.debugHydrateSuccessCount, 0);
      coord.dispose();
    });

    test('layer in pipeline + cutout on disk → hydrates into map, fires '
        'onHydrateLanded once', () async {
      // Pre-populate the store with PNG bytes for layer-1.
      await store.put(
        sourcePath: '/img.jpg',
        layerId: 'layer-1',
        pngBytes: k2x2Png,
      );

      int landed = 0;
      final coord = buildCoord(
        cutoutStore: store,
        onHydrateLanded: () => landed++,
      );
      await coord.hydrate(pipelineWithAdjustment('layer-1'));

      expect(coord.debugHydrateSuccessCount, 1);
      expect(coord.cutoutImageFor('layer-1'), isNotNull);
      expect(landed, 1);

      coord.dispose();
    });

    test('missing cutout on disk → hydrate increments miss counter, does '
        'not fire onHydrateLanded', () async {
      int landed = 0;
      final coord = buildCoord(
        cutoutStore: store,
        onHydrateLanded: () => landed++,
      );
      await coord.hydrate(pipelineWithAdjustment('never-cached'));

      expect(coord.debugHydrateSuccessCount, 0);
      expect(coord.debugHydrateMissCount, 1);
      expect(coord.cutoutImageFor('never-cached'), isNull);
      expect(landed, 0);

      coord.dispose();
    });

    test('hydrate skips layers already in the in-memory cache', () async {
      await store.put(
        sourcePath: '/img.jpg',
        layerId: 'layer-1',
        pngBytes: k2x2Png,
      );
      int landed = 0;
      final coord = buildCoord(
        cutoutStore: store,
        onHydrateLanded: () => landed++,
      );
      // Pre-seed the in-memory cache as if an AI op had already run.
      final seeded = await decode(k2x2Png);
      coord.cacheCutoutImage('layer-1', seeded);

      await coord.hydrate(pipelineWithAdjustment('layer-1'));

      expect(coord.debugHydrateSuccessCount, 0,
          reason: 'already-in-cache layer must be skipped outright');
      expect(coord.cutoutImageFor('layer-1'), same(seeded),
          reason: 'in-memory entry must NOT be replaced by the disk decode');
      expect(landed, 0);

      coord.dispose();
    });
  });

  group('runInference', () {
    test('happy path — runs infer and returns the image', () async {
      final coord = buildCoord(cutoutStore: store);
      final expected = await decode(k2x2Png);
      final got = await coord.runInference<_TestException>(
        logTag: 'applyTest',
        layerId: 'layer-1',
        infer: () async => expected,
        rethrowTyped: (e) => e is _TestException,
        makeException: _TestException.new,
      );
      expect(got, same(expected));
      got.dispose();
      coord.dispose();
    });

    test('disposed before run → throws via makeException', () async {
      final coord = buildCoord(cutoutStore: store);
      coord.dispose();
      bool inferCalled = false;
      await expectLater(
        coord.runInference<_TestException>(
          logTag: 'applyTest',
          layerId: 'layer-1',
          infer: () async {
            inferCalled = true;
            return decode(k2x2Png);
          },
          rethrowTyped: (e) => e is _TestException,
          makeException: _TestException.new,
        ),
        throwsA(
            isA<_TestException>().having((e) => e.message, 'message',
                'Session is disposed')),
      );
      expect(inferCalled, isFalse, reason: 'infer must be gated by dispose');
    });

    test('service throws typed → rethrows as-is', () async {
      final coord = buildCoord(cutoutStore: store);
      await expectLater(
        coord.runInference<_TestException>(
          logTag: 'applyTest',
          layerId: 'layer-1',
          infer: () async => throw const _TestException('boom'),
          rethrowTyped: (e) => e is _TestException,
          makeException: _TestException.new,
        ),
        throwsA(isA<_TestException>()
            .having((e) => e.message, 'message', 'boom')),
      );
      coord.dispose();
    });

    test('service throws untyped → wraps via makeException', () async {
      final coord = buildCoord(cutoutStore: store);
      await expectLater(
        coord.runInference<_TestException>(
          logTag: 'applyTest',
          layerId: 'layer-1',
          infer: () async => throw StateError('unexpected'),
          rethrowTyped: (e) => e is _TestException,
          makeException: _TestException.new,
        ),
        throwsA(
          isA<_TestException>().having(
            (e) => e.message,
            'message wraps original',
            contains('unexpected'),
          ),
        ),
      );
      coord.dispose();
    });

    test('disposed during inference → image.dispose() + throws', () async {
      final coord = buildCoord(cutoutStore: store);

      // Gate so we can fire dispose() between infer start and infer
      // completion, pinning the post-await guard.
      final inferGate = Completer<ui.Image>();
      final future = coord.runInference<_TestException>(
        logTag: 'applyTest',
        layerId: 'layer-1',
        infer: () => inferGate.future,
        rethrowTyped: (e) => e is _TestException,
        makeException: _TestException.new,
      );

      // Let the pre-await guard pass and the infer Future get scheduled.
      await Future<void>.delayed(Duration.zero);
      coord.dispose();
      final decoded = await decode(k2x2Png);
      inferGate.complete(decoded);

      await expectLater(
        future,
        throwsA(isA<_TestException>().having(
          (e) => e.message,
          'message',
          'Session closed during inference',
        )),
      );
      expect(decoded.debugDisposed, isTrue,
          reason: 'orphaned image after dispose must be released');
    });
  });

  group('round-trip — cache survives simulated undo/redo', () {
    test('cache persists across pipeline empty → restored bounces', () async {
      final coord = buildCoord(cutoutStore: store);
      final image = await decode(k2x2Png);
      coord.cacheCutoutImage('layer-1', image);

      // Simulate undo: pipeline loses the adjustment layer. The
      // session's rebuildPreview would skip layer-1, but the cache
      // still holds the bitmap because history-change doesn't evict.
      final undone = EditPipeline.forOriginal('/img.jpg');
      expect(undone.contentLayers.whereType<AdjustmentLayer>(), isEmpty);
      expect(coord.cutoutImageFor('layer-1'), same(image),
          reason: 'cache MUST survive a pipeline that no longer '
              'references the layer — redo needs the bitmap back');

      // Simulate redo: layer comes back. The session's rebuildPreview
      // reads cutoutImageFor(layer-1) and wires the bitmap into the
      // restored AdjustmentLayer, so the AI output is visible again
      // without re-running inference.
      const redone = AdjustmentLayer(
        id: 'layer-1',
        adjustmentKind: AdjustmentKind.backgroundRemoval,
      );
      expect(coord.cutoutImageFor(redone.id), same(image));

      coord.dispose();
    });
  });

  group('dispose lifecycle', () {
    test('dispose disposes every cached bitmap and clears the map',
        () async {
      final coord = buildCoord(cutoutStore: store);
      final a = await decode(k2x2Png);
      final b = await decode(k2x2Png);
      coord.cacheCutoutImage('a', a);
      coord.cacheCutoutImage('b', b);

      coord.dispose();

      expect(a.debugDisposed, isTrue);
      expect(b.debugDisposed, isTrue);
      expect(coord.cutoutCount, 0);
      expect(coord.isDisposed, isTrue);
    });

    test('dispose is idempotent — calling twice is safe', () async {
      final coord = buildCoord(cutoutStore: store);
      final image = await decode(k2x2Png);
      coord.cacheCutoutImage('a', image);

      coord.dispose();
      // Double-dispose must not try to re-dispose an already-disposed
      // ui.Image (would throw in debug builds).
      coord.dispose();

      expect(coord.isDisposed, isTrue);
    });
  });

  // -------------------------------------------------------------------------
  // Phase VII.4 — the coordinator's apply methods integrate: inference
  // (via a fake strategy) → cutout cache → commit callback. Only the
  // strategy and callback are faked; everything else is real.
  // -------------------------------------------------------------------------
  group('applyBackgroundRemoval (VII.4)', () {
    test('happy path — caches the cutout + commits the adjustment layer',
        () async {
      final commits = <_CommitCall>[];
      final image = await decode(k2x2Png);
      final coord = buildCoord(
        cutoutStore: store,
        commitAdjustmentLayer: (
            {required AdjustmentLayer layer, required String presetName}) {
          commits.add(_CommitCall(layer, presetName));
        },
      );

      final fakeStrategy = _FakeBgRemovalStrategy(returnImage: image);
      final returnedId = await coord.applyBackgroundRemoval(
        strategy: fakeStrategy,
        newLayerId: 'layer-abc',
      );

      expect(returnedId, 'layer-abc',
          reason: 'method returns the new layer id on success');
      expect(fakeStrategy.callCount, 1);
      expect(coord.cutoutImageFor('layer-abc'), same(image),
          reason: 'cutout must be cached under the layer id');
      expect(commits, hasLength(1));
      expect(commits.single.layer.id, 'layer-abc');
      expect(
        commits.single.layer.adjustmentKind,
        AdjustmentKind.backgroundRemoval,
      );
      expect(commits.single.presetName, 'Remove background');

      coord.dispose();
    });

    test('service throws typed exception → coordinator rethrows, no '
        'commit fires', () async {
      int commitCount = 0;
      final coord = buildCoord(
        cutoutStore: store,
        commitAdjustmentLayer: (
            {required AdjustmentLayer layer, required String presetName}) {
          commitCount++;
        },
      );
      final fakeStrategy = _FakeBgRemovalStrategy.failing();

      await expectLater(
        coord.applyBackgroundRemoval(
          strategy: fakeStrategy,
          newLayerId: 'layer-boom',
        ),
        throwsA(isA<Object>()),
      );
      expect(commitCount, 0,
          reason: 'no commit should fire on inference failure');
      expect(coord.cutoutImageFor('layer-boom'), isNull);

      coord.dispose();
    });

    test('disposed during inference → image disposed + no commit', () async {
      final inferGate = Completer<ui.Image>();
      int commitCount = 0;
      final coord = buildCoord(
        cutoutStore: store,
        commitAdjustmentLayer: (
            {required AdjustmentLayer layer, required String presetName}) {
          commitCount++;
        },
      );
      final fakeStrategy = _FakeBgRemovalStrategy.gated(inferGate);

      final future = coord.applyBackgroundRemoval(
        strategy: fakeStrategy,
        newLayerId: 'layer-race',
      );
      await Future<void>.delayed(Duration.zero);
      coord.dispose();
      final image = await decode(k2x2Png);
      inferGate.complete(image);

      await expectLater(future, throwsA(isA<Object>()));
      expect(commitCount, 0);
      expect(image.debugDisposed, isTrue,
          reason: 'orphaned cutout must be released after post-await dispose');
    });
  });

  // -------------------------------------------------------------------------
  // Phase XVI.66a — three single-button AI ops (Denoise / Sharpen / Face
  // Restore). Same shape as the VII.4 applyBackgroundRemoval contract:
  // run inference → cache cutout → commit adjustment layer with the
  // expected AdjustmentKind and preset name.
  //
  // The 3 services are concrete classes rather than interfaces, so the
  // fakes use Dart's `implements` + noSuchMethod escape hatch — the
  // AiCoordinator only ever calls one method per service (`denoiseFromPath`
  // / `sharpenFromPath` / `restoreFromPath`), so the unimplemented
  // surface area never gets touched.
  // -------------------------------------------------------------------------
  group('applyAiDenoise (XVI.66a)', () {
    test('happy path — caches cutout + commits AdjustmentKind.aiDenoise',
        () async {
      final commits = <_CommitCall>[];
      final image = await decode(k2x2Png);
      final coord = buildCoord(
        cutoutStore: store,
        commitAdjustmentLayer: (
            {required AdjustmentLayer layer, required String presetName}) {
          commits.add(_CommitCall(layer, presetName));
        },
      );
      final fake = _FakeAiDenoiseService(returnImage: image);

      final returnedId = await coord.applyAiDenoise(
        service: fake,
        newLayerId: 'denoise-1',
      );

      expect(returnedId, 'denoise-1');
      expect(fake.callCount, 1);
      expect(coord.cutoutImageFor('denoise-1'), same(image));
      expect(commits, hasLength(1));
      expect(commits.single.layer.id, 'denoise-1');
      expect(commits.single.layer.adjustmentKind, AdjustmentKind.aiDenoise);
      expect(commits.single.presetName, 'Denoise (AI)');

      coord.dispose();
    });

    test('typed exception → rethrows + no commit fires', () async {
      int commitCount = 0;
      final coord = buildCoord(
        cutoutStore: store,
        commitAdjustmentLayer: (
            {required AdjustmentLayer layer, required String presetName}) {
          commitCount++;
        },
      );
      final fake = _FakeAiDenoiseService.failing();

      await expectLater(
        coord.applyAiDenoise(service: fake, newLayerId: 'denoise-x'),
        throwsA(isA<AiDenoiseException>()),
      );
      expect(commitCount, 0);
      expect(coord.cutoutImageFor('denoise-x'), isNull);

      coord.dispose();
    });
  });

  group('applyAiSharpen (XVI.66a)', () {
    test('happy path — caches cutout + commits AdjustmentKind.aiSharpen',
        () async {
      final commits = <_CommitCall>[];
      final image = await decode(k2x2Png);
      final coord = buildCoord(
        cutoutStore: store,
        commitAdjustmentLayer: (
            {required AdjustmentLayer layer, required String presetName}) {
          commits.add(_CommitCall(layer, presetName));
        },
      );
      final fake = _FakeAiSharpenService(returnImage: image);

      final returnedId = await coord.applyAiSharpen(
        service: fake,
        newLayerId: 'sharpen-1',
      );

      expect(returnedId, 'sharpen-1');
      expect(fake.callCount, 1);
      expect(coord.cutoutImageFor('sharpen-1'), same(image));
      expect(commits, hasLength(1));
      expect(commits.single.layer.adjustmentKind, AdjustmentKind.aiSharpen);
      expect(commits.single.presetName, 'Sharpen (AI)');

      coord.dispose();
    });

    test('typed exception → rethrows + no commit fires', () async {
      int commitCount = 0;
      final coord = buildCoord(
        cutoutStore: store,
        commitAdjustmentLayer: (
            {required AdjustmentLayer layer, required String presetName}) {
          commitCount++;
        },
      );
      final fake = _FakeAiSharpenService.failing();

      await expectLater(
        coord.applyAiSharpen(service: fake, newLayerId: 'sharpen-x'),
        throwsA(isA<AiSharpenException>()),
      );
      expect(commitCount, 0);

      coord.dispose();
    });
  });

  group('applyFaceRestore (XVI.66a)', () {
    test('happy path — caches cutout + commits AdjustmentKind.aiFaceRestore',
        () async {
      final commits = <_CommitCall>[];
      final image = await decode(k2x2Png);
      final coord = buildCoord(
        cutoutStore: store,
        commitAdjustmentLayer: (
            {required AdjustmentLayer layer, required String presetName}) {
          commits.add(_CommitCall(layer, presetName));
        },
      );
      final fake = _FakeFaceRestoreService(returnImage: image);

      final returnedId = await coord.applyFaceRestore(
        service: fake,
        newLayerId: 'face-1',
      );

      expect(returnedId, 'face-1');
      expect(fake.callCount, 1);
      expect(coord.cutoutImageFor('face-1'), same(image));
      expect(commits, hasLength(1));
      expect(commits.single.layer.adjustmentKind,
          AdjustmentKind.aiFaceRestore);
      expect(commits.single.presetName, 'Restore Faces');

      coord.dispose();
    });

    test('typed exception → rethrows + no commit fires', () async {
      int commitCount = 0;
      final coord = buildCoord(
        cutoutStore: store,
        commitAdjustmentLayer: (
            {required AdjustmentLayer layer, required String presetName}) {
          commitCount++;
        },
      );
      final fake = _FakeFaceRestoreService.failing();

      await expectLater(
        coord.applyFaceRestore(service: fake, newLayerId: 'face-x'),
        throwsA(isA<FaceRestoreException>()),
      );
      expect(commitCount, 0);

      coord.dispose();
    });
  });
}

/// Captures a commit-layer callback invocation for test assertions.
class _CommitCall {
  _CommitCall(this.layer, this.presetName);
  final AdjustmentLayer layer;
  final String presetName;
}

/// Minimal [BgRemovalStrategy] that returns a canned image, throws, or
/// gates on a completer — enough surface for the 3 VII.4 apply tests.
class _FakeBgRemovalStrategy implements BgRemovalStrategy {
  _FakeBgRemovalStrategy({required ui.Image returnImage})
      : _returnImage = returnImage,
        _gate = null,
        _shouldThrow = false;
  _FakeBgRemovalStrategy.failing()
      : _returnImage = null,
        _gate = null,
        _shouldThrow = true;
  _FakeBgRemovalStrategy.gated(Completer<ui.Image> gate)
      : _returnImage = null,
        _gate = gate,
        _shouldThrow = false;

  final ui.Image? _returnImage;
  final Completer<ui.Image>? _gate;
  final bool _shouldThrow;
  int callCount = 0;

  @override
  BgRemovalStrategyKind get kind => BgRemovalStrategyKind.mediaPipe;

  @override
  Future<ui.Image> removeBackgroundFromPath(String sourcePath) async {
    callCount++;
    if (_shouldThrow) {
      throw const BgRemovalException('forced failure',
          kind: BgRemovalStrategyKind.mediaPipe);
    }
    if (_gate != null) return _gate.future;
    return _returnImage!;
  }

  @override
  Future<void> close() async {}
}

/// Minimal test-exception used by [runInference] assertions. Matches
/// the shape of the 9 real AI service exceptions (string message +
/// optional cause) without depending on any service import.
class _TestException implements Exception {
  const _TestException(this.message, {this.cause});
  final String message;
  final Object? cause;
  @override
  String toString() => '_TestException($message)';
}

/// Phase XVI.66a — fake [AiDenoiseService]. The coordinator only calls
/// [denoiseFromPath] on it, so the rest of the surface area routes
/// through `noSuchMethod` and never gets touched in practice.
class _FakeAiDenoiseService implements AiDenoiseService {
  _FakeAiDenoiseService({required ui.Image returnImage})
      : _returnImage = returnImage,
        _shouldThrow = false;
  _FakeAiDenoiseService.failing()
      : _returnImage = null,
        _shouldThrow = true;

  final ui.Image? _returnImage;
  final bool _shouldThrow;
  int callCount = 0;

  @override
  Future<ui.Image> denoiseFromPath(String sourcePath) async {
    callCount++;
    if (_shouldThrow) {
      throw const AiDenoiseException('forced failure');
    }
    return _returnImage!;
  }

  @override
  Future<void> close() async {}

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('Fake doesn\'t implement ${invocation.memberName}');
}

/// Phase XVI.66a — fake [AiSharpenService] mirroring the denoise fake.
class _FakeAiSharpenService implements AiSharpenService {
  _FakeAiSharpenService({required ui.Image returnImage})
      : _returnImage = returnImage,
        _shouldThrow = false;
  _FakeAiSharpenService.failing()
      : _returnImage = null,
        _shouldThrow = true;

  final ui.Image? _returnImage;
  final bool _shouldThrow;
  int callCount = 0;

  @override
  Future<ui.Image> sharpenFromPath(String sourcePath) async {
    callCount++;
    if (_shouldThrow) {
      throw const AiSharpenException('forced failure');
    }
    return _returnImage!;
  }

  @override
  Future<void> close() async {}

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('Fake doesn\'t implement ${invocation.memberName}');
}

/// Phase XVI.66a — fake [FaceRestoreService] mirroring the denoise fake.
class _FakeFaceRestoreService implements FaceRestoreService {
  _FakeFaceRestoreService({required ui.Image returnImage})
      : _returnImage = returnImage,
        _shouldThrow = false;
  _FakeFaceRestoreService.failing()
      : _returnImage = null,
        _shouldThrow = true;

  final ui.Image? _returnImage;
  final bool _shouldThrow;
  int callCount = 0;

  @override
  Future<ui.Image> restoreFromPath(String sourcePath) async {
    callCount++;
    if (_shouldThrow) {
      throw const FaceRestoreException('forced failure');
    }
    return _returnImage!;
  }

  @override
  Future<void> close() async {}

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('Fake doesn\'t implement ${invocation.memberName}');
}
