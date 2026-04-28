import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';

import 'package:image_editor/ai/services/face_detect/face_detection_cache.dart';
import 'package:image_editor/ai/services/face_detect/face_detection_service.dart';

/// Unit tests for `FaceDetectionCache` (Phase V.1).
///
/// The cache is a self-contained map of in-flight detections. The
/// Phase V.1 invariant it underwrites is: three sequential calls
/// for the same source path invoke the detector exactly once. The
/// tests below pin that invariant and the supporting guarantees:
/// concurrent callers converge, failures retry, empty-list results
/// are stable.
void main() {
  DetectedFace fakeFace(String tag) {
    // Shape doesn't matter for cache tests; pick deterministic values
    // so assertions can compare faces with `same`.
    return const DetectedFace(
      boundingBox: ui.Rect.fromLTWH(0, 0, 100, 100),
      landmarks: {},
      headEulerAngleZ: 0.0,
    );
  }

  group('FaceDetectionCache', () {
    test('first call invokes detect and returns its result', () async {
      final cache = FaceDetectionCache();
      int calls = 0;
      final out = await cache.getOrDetect(
        sourcePath: '/a.jpg',
        detect: () async {
          calls++;
          return [fakeFace('a1')];
        },
      );
      expect(calls, 1);
      expect(out, hasLength(1));
      expect(cache.debugDetectCallCount, 1);
      expect(cache.trackedPathCount, 1);
    });

    test('second call with same path hits cache — detect NOT invoked again',
        () async {
      final cache = FaceDetectionCache();
      int calls = 0;
      final first = await cache.getOrDetect(
        sourcePath: '/a.jpg',
        detect: () async {
          calls++;
          return [fakeFace('a1')];
        },
      );
      final second = await cache.getOrDetect(
        sourcePath: '/a.jpg',
        detect: () async {
          calls++;
          // Return a different list so a bug that ignored the cache
          // would change the result shape on the second call.
          return [fakeFace('a2'), fakeFace('a3')];
        },
      );
      expect(calls, 1, reason: 'second call must reuse first future');
      expect(cache.debugDetectCallCount, 1);
      expect(second, same(first),
          reason: 'second call returns the same resolved list');
    });

    test('three calls with same path invoke detect exactly once '
        '(the Phase V.1 core invariant)', () async {
      final cache = FaceDetectionCache();
      int calls = 0;
      Future<List<DetectedFace>> run() => cache.getOrDetect(
            sourcePath: '/a.jpg',
            detect: () async {
              calls++;
              return [fakeFace('a')];
            },
          );
      await run();
      await run();
      await run();
      expect(calls, 1, reason: 'three calls → one detection');
      expect(cache.debugDetectCallCount, 1);
    });

    test('different source paths hit separate cache entries', () async {
      final cache = FaceDetectionCache();
      int calls = 0;
      await cache.getOrDetect(
        sourcePath: '/a.jpg',
        detect: () async {
          calls++;
          return [fakeFace('a')];
        },
      );
      await cache.getOrDetect(
        sourcePath: '/b.jpg',
        detect: () async {
          calls++;
          return [fakeFace('b')];
        },
      );
      expect(calls, 2, reason: 'different paths each trigger detection');
      expect(cache.trackedPathCount, 2);
    });

    test('concurrent same-path callers converge on one detection', () async {
      final cache = FaceDetectionCache();
      int calls = 0;
      final completer = Completer<List<DetectedFace>>();
      final f1 = cache.getOrDetect(
        sourcePath: '/a.jpg',
        detect: () {
          calls++;
          return completer.future;
        },
      );
      final f2 = cache.getOrDetect(
        sourcePath: '/a.jpg',
        detect: () {
          calls++;
          // This closure should never fire — the second caller
          // hits the in-flight future from f1.
          return completer.future;
        },
      );
      final f3 = cache.getOrDetect(
        sourcePath: '/a.jpg',
        detect: () {
          calls++;
          return completer.future;
        },
      );
      // Only now resolve the first detection.
      completer.complete([fakeFace('a')]);
      final r1 = await f1;
      final r2 = await f2;
      final r3 = await f3;
      expect(calls, 1,
          reason: 'only the first caller invokes the injected detect closure');
      expect(r2, same(r1), reason: 'second caller sees the same resolved list');
      expect(r3, same(r1), reason: 'third caller sees the same resolved list');
      expect(cache.debugDetectCallCount, 1);
    });

    test('failure is NOT cached — retry invokes detect again', () async {
      final cache = FaceDetectionCache();
      int calls = 0;
      final failing = cache.getOrDetect(
        sourcePath: '/a.jpg',
        detect: () async {
          calls++;
          throw StateError('boom');
        },
      );
      await expectLater(failing, throwsA(isA<StateError>()));
      expect(calls, 1);
      // Cache entry should be gone so the retry actually retries.
      expect(cache.trackedPathCount, 0,
          reason: 'failed entry removed from cache');
      final retry = await cache.getOrDetect(
        sourcePath: '/a.jpg',
        detect: () async {
          calls++;
          return [fakeFace('a-retry')];
        },
      );
      expect(calls, 2, reason: 'retry fires a fresh detection');
      expect(retry, hasLength(1));
      expect(cache.debugDetectCallCount, 2);
    });

    test('concurrent callers on a failing detection all see the error '
        'and a subsequent call retries', () async {
      final cache = FaceDetectionCache();
      int calls = 0;
      final completer = Completer<List<DetectedFace>>();
      final f1 = cache.getOrDetect(
        sourcePath: '/a.jpg',
        detect: () {
          calls++;
          return completer.future;
        },
      );
      final f2 = cache.getOrDetect(
        sourcePath: '/a.jpg',
        detect: () => completer.future,
      );
      completer.completeError(StateError('shared boom'));
      await expectLater(f1, throwsA(isA<StateError>()));
      await expectLater(f2, throwsA(isA<StateError>()));
      expect(calls, 1, reason: 'second concurrent caller did not re-invoke');
      // Post-failure cache is empty; a third caller gets a fresh detect.
      final f3 = await cache.getOrDetect(
        sourcePath: '/a.jpg',
        detect: () async {
          calls++;
          return [fakeFace('recovered')];
        },
      );
      expect(calls, 2);
      expect(f3, hasLength(1));
    });

    test('empty-list success IS cached — "no faces detected" is stable',
        () async {
      final cache = FaceDetectionCache();
      int calls = 0;
      final r1 = await cache.getOrDetect(
        sourcePath: '/a.jpg',
        detect: () async {
          calls++;
          return const <DetectedFace>[];
        },
      );
      final r2 = await cache.getOrDetect(
        sourcePath: '/a.jpg',
        detect: () async {
          calls++;
          return [fakeFace('should not be seen')];
        },
      );
      expect(calls, 1,
          reason: 'empty list is a valid stable result — keep the entry');
      expect(r1, isEmpty);
      expect(r2, isEmpty);
      expect(r2, same(r1));
    });

    test('clear() drops every entry; next call re-detects', () async {
      final cache = FaceDetectionCache();
      int calls = 0;
      await cache.getOrDetect(
        sourcePath: '/a.jpg',
        detect: () async {
          calls++;
          return [fakeFace('a')];
        },
      );
      await cache.getOrDetect(
        sourcePath: '/b.jpg',
        detect: () async {
          calls++;
          return [fakeFace('b')];
        },
      );
      expect(cache.trackedPathCount, 2);
      cache.clear();
      expect(cache.trackedPathCount, 0);
      await cache.getOrDetect(
        sourcePath: '/a.jpg',
        detect: () async {
          calls++;
          return [fakeFace('a-again')];
        },
      );
      expect(calls, 3, reason: 'post-clear the cache is cold again');
      expect(cache.trackedPathCount, 1);
    });

    test('clear() on empty cache is a no-op', () {
      final cache = FaceDetectionCache();
      // Should not throw or log anything weird.
      cache.clear();
      expect(cache.trackedPathCount, 0);
      expect(cache.debugDetectCallCount, 0);
    });

    test('debugDetectCallCount grows with misses, not with hits', () async {
      final cache = FaceDetectionCache();
      await cache.getOrDetect(
        sourcePath: '/a.jpg',
        detect: () async => [fakeFace('a')],
      );
      await cache.getOrDetect(
        sourcePath: '/a.jpg',
        detect: () async => [fakeFace('a2')],
      );
      await cache.getOrDetect(
        sourcePath: '/b.jpg',
        detect: () async => [fakeFace('b')],
      );
      await cache.getOrDetect(
        sourcePath: '/b.jpg',
        detect: () async => [fakeFace('b2')],
      );
      expect(cache.debugDetectCallCount, 2,
          reason: 'two distinct paths → two detect invocations total');
    });

    // Phase XVI.38 — `tryGetCached` is the synchronous read smart-crop
    // chips depend on. Unlike `getOrDetect`, it must NEVER fire a
    // detection: the chip taps need to render the cached state, not
    // wait for a future.
    test('tryGetCached returns null before any detect runs', () {
      final cache = FaceDetectionCache();
      expect(cache.tryGetCached('/a.jpg'), isNull);
    });

    test('tryGetCached returns the resolved face list after detect lands',
        () async {
      final cache = FaceDetectionCache();
      await cache.getOrDetect(
        sourcePath: '/a.jpg',
        detect: () async => [fakeFace('a')],
      );
      final cached = cache.tryGetCached('/a.jpg');
      expect(cached, isNotNull);
      expect(cached, hasLength(1));
    });

    test('tryGetCached distinguishes "no faces" from "not yet detected"',
        () async {
      // Phase V.1 cached an empty success result; XVI.38 mirrors it so
      // the smart-crop chip can show "no face → image-centre fallback"
      // without re-running detection.
      final cache = FaceDetectionCache();
      await cache.getOrDetect(
        sourcePath: '/a.jpg',
        detect: () async => const <DetectedFace>[],
      );
      final cached = cache.tryGetCached('/a.jpg');
      expect(cached, isNotNull,
          reason: 'empty list ≠ "not detected" — returns []');
      expect(cached, isEmpty);
    });

    test('tryGetCached is null while a detection is still in flight',
        () async {
      final cache = FaceDetectionCache();
      final completer = Completer<List<DetectedFace>>();
      final future = cache.getOrDetect(
        sourcePath: '/a.jpg',
        detect: () => completer.future,
      );
      // Detection hasn't completed yet — tryGetCached must NOT
      // expose a half-state to callers.
      expect(cache.tryGetCached('/a.jpg'), isNull);
      completer.complete([fakeFace('a')]);
      await future;
      expect(cache.tryGetCached('/a.jpg'), hasLength(1));
    });

    test('clear() also wipes the synchronous mirror', () async {
      final cache = FaceDetectionCache();
      await cache.getOrDetect(
        sourcePath: '/a.jpg',
        detect: () async => [fakeFace('a')],
      );
      expect(cache.tryGetCached('/a.jpg'), hasLength(1));
      cache.clear();
      expect(cache.tryGetCached('/a.jpg'), isNull);
    });
  });
}
