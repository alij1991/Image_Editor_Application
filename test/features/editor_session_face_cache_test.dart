import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

import 'package:image_editor/ai/services/face_detect/face_detection_service.dart';
import 'package:image_editor/engine/layers/cutout_store.dart';
import 'package:image_editor/engine/pipeline/preview_proxy.dart';
import 'package:image_editor/features/editor/data/project_store.dart';
import 'package:image_editor/features/editor/presentation/notifiers/editor_session.dart';

/// Phase V.1 session-level integration test.
///
/// The cache class has its own correctness tests
/// (`test/ai/face_detection_cache_test.dart`); this file pins the
/// **wiring** invariant: `EditorSession.detectFacesCached` routes
/// through a single session-lifetime cache, so three sequential
/// calls on the same `sourcePath` invoke the injected detector
/// exactly once.
///
/// The three beauty-service `applyXxx` methods (`applyPortraitSmooth`,
/// `applyEyeBrighten`, `applyTeethWhiten`, and the follow-on
/// `applyFaceReshape`) each forward their detection call through
/// `detectFacesCached`; this test exercises that forward path
/// directly rather than driving the full beauty pipelines (which
/// would require real image fixtures + pixel-op machinery outside
/// V.1's scope). Static inspection of the four `apply*` methods
/// confirms they all call `detectFacesCached(...)` — the shared
/// cache state pinned here is the core guarantee.
///
/// ## Test-harness minimum
///
/// `EditorSession.start` needs a `PreviewProxy` with a loaded image.
/// `PreviewProxy.loadFromBytes` is the test path — it decodes a
/// hard-coded 1×1 transparent PNG so we avoid filesystem fixtures.
/// `MementoStore` degrades gracefully to RAM-only when path_provider
/// is unavailable (the documented fallback in its `init`).
/// `ProjectStore` and `CutoutStore` accept `rootOverride` so tests
/// write to a tempDir instead of the real app-docs dir.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  /// Valid 1×1 RGBA PNG generated at test-load time via the `image`
  /// package. Sufficient to satisfy [PreviewProxy.loadFromBytes] —
  /// which calls `ui.instantiateImageCodec` — without a disk fixture.
  final kTinyPng = Uint8List.fromList(
    img.encodePng(img.Image(width: 1, height: 1)),
  );

  Future<EditorSession> buildSession(Directory tmp) async {
    final proxy = PreviewProxy(sourcePath: '/fake/a.jpg', longEdge: 64);
    await proxy.loadFromBytes(kTinyPng);
    final projects = Directory('${tmp.path}/projects')..createSync();
    final cutouts = Directory('${tmp.path}/cutouts')..createSync();
    return EditorSession.start(
      sourcePath: '/fake/a.jpg',
      proxy: proxy,
      projectStore: ProjectStore(rootOverride: projects),
      cutoutStore: CutoutStore(rootOverride: cutouts),
    );
  }

  group('EditorSession face-detection cache (Phase V.1)', () {
    late Directory tmp;

    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('es_face_cache_');
    });

    tearDown(() async {
      if (tmp.existsSync()) tmp.deleteSync(recursive: true);
    });

    test('three detectFacesCached calls on same sourcePath → 1 detect call '
        '(the Phase V.1 invariant)', () async {
      final session = await buildSession(tmp);
      final detector = _CountingFaceDetectionService(facesToReturn: const []);

      await session.detectFacesCached(detector: detector);
      await session.detectFacesCached(detector: detector);
      await session.detectFacesCached(detector: detector);

      expect(detector.callCount, 1,
          reason: 'three session calls on same sourcePath must coalesce '
              'to a single detector invocation');
      expect(session.debugFaceDetectionCallCount, 1,
          reason: 'session forwards the cache counter correctly');

      await session.dispose();
    });

    test('cached result survives across calls (same faces list returned)',
        () async {
      final session = await buildSession(tmp);
      const returned = [
        DetectedFace(
          boundingBox: ui.Rect.fromLTWH(10, 10, 50, 50),
          landmarks: {},
          headEulerAngleZ: 2.0,
        ),
      ];
      final detector = _CountingFaceDetectionService(facesToReturn: returned);

      final first = await session.detectFacesCached(detector: detector);
      final second = await session.detectFacesCached(detector: detector);

      expect(second, same(first),
          reason: 'same identity across calls proves the cache returns '
              'the memoized future, not a fresh detection');
      expect(first, hasLength(1));

      await session.dispose();
    });

    test('detector failure is not cached — next call retries', () async {
      final session = await buildSession(tmp);
      final detector = _CountingFaceDetectionService.failing();

      await expectLater(
        session.detectFacesCached(detector: detector),
        throwsA(isA<FaceDetectionException>()),
      );
      expect(detector.callCount, 1);

      // Second call should retry (cache did not memoize the failure).
      detector.switchToSuccess(const []);
      await session.detectFacesCached(detector: detector);
      expect(detector.callCount, 2,
          reason: 'after a failure, the cache re-invokes the detector');
      expect(session.debugFaceDetectionCallCount, 2);

      await session.dispose();
    });

    test('concurrent calls coalesce — 3 parallel callers → 1 detect',
        () async {
      final session = await buildSession(tmp);
      final detector = _CountingFaceDetectionService(facesToReturn: const []);

      final results = await Future.wait([
        session.detectFacesCached(detector: detector),
        session.detectFacesCached(detector: detector),
        session.detectFacesCached(detector: detector),
      ]);

      expect(detector.callCount, 1,
          reason: '3 concurrent callers share one in-flight future');
      expect(results, hasLength(3));
      expect(results[1], same(results[0]));
      expect(results[2], same(results[0]));

      await session.dispose();
    });
  });
}

/// Minimal fake that counts `detectFromPath` invocations and returns
/// a configurable list (or throws). Uses `implements` so the ML Kit
/// constructor in the real [FaceDetectionService] is never invoked —
/// the test never touches the platform channel.
class _CountingFaceDetectionService implements FaceDetectionService {
  _CountingFaceDetectionService({required this.facesToReturn}) : _fail = false;

  _CountingFaceDetectionService.failing()
      : facesToReturn = const [],
        _fail = true;

  List<DetectedFace> facesToReturn;
  bool _fail;
  int callCount = 0;

  void switchToSuccess(List<DetectedFace> faces) {
    _fail = false;
    facesToReturn = faces;
  }

  @override
  Future<List<DetectedFace>> detectFromPath(String sourcePath) async {
    callCount++;
    if (_fail) {
      throw const FaceDetectionException('synthetic test failure');
    }
    return facesToReturn;
  }

  // ----- interface carries -------------------------------------------------

  @override
  double get minFaceSize => 0.1;

  @override
  bool get enableContours => true;

  @override
  Future<void> close() async {}

  // `_detector` is private to the real service; `implements` doesn't
  // require implementing private members.
}
