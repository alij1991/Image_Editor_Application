import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:image_editor/ai/services/style_transfer/style_vector_cache.dart';

/// Phase V.5 tests for `StyleVectorCache` — sha256-keyed disk cache
/// for Magenta style-prediction vectors.
///
/// The cache sits between `StylePredictService.predictFromPath` and
/// the ML Kit run. These tests drive the cache directly with a
/// tempDir root + fake compute closures: no ML Kit, no real image
/// decode, no pixel ops.
void main() {
  late Directory tmp;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('style_vector_cache_');
  });

  tearDown(() async {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  /// Write [bytes] to a file under [tmp] and return the path. Each
  /// test gets a fresh tempDir, so the returned path is unique per
  /// call within a test but collision-free across tests.
  String writeStyleFile(List<int> bytes, {String name = 'style.jpg'}) {
    final path = '${tmp.path}/$name';
    File(path).writeAsBytesSync(bytes);
    return path;
  }

  /// Deterministic fake vector of [length] float32 values.
  /// Filled with `i * 0.01` so two vectors computed in sequence
  /// won't accidentally look identical.
  Float32List fakeVector([int length = 100, double base = 0.01]) {
    final v = Float32List(length);
    for (int i = 0; i < length; i++) {
      v[i] = i * base;
    }
    return v;
  }

  group('StyleVectorCache primitives', () {
    test('hashFile returns a stable 64-char lowercase sha256', () async {
      final cache = StyleVectorCache(rootOverride: tmp);
      final path = writeStyleFile(List<int>.generate(1024, (i) => i & 0xFF));

      final first = await cache.hashFile(path);
      final second = await cache.hashFile(path);
      expect(first, second,
          reason: 'same bytes → same sha every call');
      expect(first.length, 64);
      expect(RegExp(r'^[0-9a-f]{64}$').hasMatch(first), isTrue,
          reason: 'sha256 is lowercase hex');
    });

    test('hashFile differs for different content', () async {
      final cache = StyleVectorCache(rootOverride: tmp);
      final a = writeStyleFile([1, 2, 3, 4], name: 'a.jpg');
      final b = writeStyleFile([9, 8, 7, 6], name: 'b.jpg');
      final ha = await cache.hashFile(a);
      final hb = await cache.hashFile(b);
      expect(ha, isNot(hb));
    });

    test('hashFile is content-keyed, not path-keyed', () async {
      final cache = StyleVectorCache(rootOverride: tmp);
      final bytes = List<int>.generate(512, (i) => i * 3 & 0xFF);
      final a = writeStyleFile(bytes, name: 'same1.jpg');
      final b = writeStyleFile(bytes, name: 'same2.jpg');
      expect(await cache.hashFile(a), await cache.hashFile(b),
          reason: 'copying the same bytes under a different name '
              'must produce the same sha — enables cross-copy reuse');
    });

    test('store + load round-trips a vector', () async {
      final cache = StyleVectorCache(rootOverride: tmp);
      final v = fakeVector();
      await cache.store('abc123', v);
      final loaded = await cache.load('abc123');
      expect(loaded, isNotNull);
      expect(loaded!.length, 100);
      for (int i = 0; i < 100; i++) {
        expect(loaded[i], closeTo(v[i], 1e-6),
            reason: 'index $i: $v[i] vs ${loaded[i]}');
      }
    });

    test('load returns null for a missing sha', () async {
      final cache = StyleVectorCache(rootOverride: tmp);
      expect(await cache.load('does-not-exist'), isNull);
    });

    test('load returns null when the file is the wrong length', () async {
      // Simulates a corrupt-on-disk state (truncated write from an
      // older version, or a manual fs poke).
      final cache = StyleVectorCache(rootOverride: tmp);
      final file = File('${tmp.path}/corrupt.bin');
      file.writeAsBytesSync(Uint8List(123)); // 123 != 100 * 4 = 400
      expect(await cache.load('corrupt'), isNull);
    });

    test('store skips wrong-length vectors instead of writing them',
        () async {
      final cache = StyleVectorCache(rootOverride: tmp, vectorLength: 100);
      await cache.store('bad', Float32List(50));
      final file = File('${tmp.path}/bad.bin');
      expect(file.existsSync(), isFalse,
          reason: 'wrong-length input must not pollute the cache');
    });

    test('store overwrites an existing entry', () async {
      final cache = StyleVectorCache(rootOverride: tmp);
      final a = fakeVector(100, 0.01);
      final b = fakeVector(100, 0.99);
      await cache.store('sha', a);
      await cache.store('sha', b);
      final loaded = await cache.load('sha');
      expect(loaded, isNotNull);
      expect(loaded![50], closeTo(50 * 0.99, 1e-6));
    });

    test('clear removes every .bin entry but leaves the directory',
        () async {
      final cache = StyleVectorCache(rootOverride: tmp);
      await cache.store('a', fakeVector());
      await cache.store('b', fakeVector());
      // Non-.bin files (e.g. atomic .tmp leftovers) aren't our
      // concern but shouldn't block a clear; seed one to pin the
      // no-effect on them.
      File('${tmp.path}/unrelated.txt').writeAsStringSync('preserved');
      await cache.clear();
      expect(File('${tmp.path}/a.bin').existsSync(), isFalse);
      expect(File('${tmp.path}/b.bin').existsSync(), isFalse);
      expect(File('${tmp.path}/unrelated.txt').existsSync(), isTrue,
          reason: 'clear scopes to .bin vectors only');
    });
  });

  group('StyleVectorCache.getOrCompute', () {
    test('cold cache → compute fires, vector persisted', () async {
      final cache = StyleVectorCache(rootOverride: tmp);
      final path = writeStyleFile(const [1, 2, 3, 4, 5]);
      int computeCalls = 0;
      final out = await cache.getOrCompute(
        stylePath: path,
        compute: () async {
          computeCalls++;
          return fakeVector();
        },
      );
      expect(computeCalls, 1);
      expect(cache.debugComputeCallCount, 1);
      expect(cache.debugCacheHitCount, 0);
      expect(out.length, 100);
      // Second call on the same path → cache hit.
      final second = await cache.getOrCompute(
        stylePath: path,
        compute: () async {
          computeCalls++;
          return fakeVector(100, 999.0); // sentinel — must not be returned
        },
      );
      expect(computeCalls, 1, reason: 'compute must NOT fire on cache hit');
      expect(cache.debugComputeCallCount, 1);
      expect(cache.debugCacheHitCount, 1);
      for (int i = 0; i < 100; i++) {
        expect(second[i], closeTo(out[i], 1e-6));
      }
    });

    test('same bytes under different paths share one cache entry',
        () async {
      final cache = StyleVectorCache(rootOverride: tmp);
      final bytes = List<int>.generate(256, (i) => i & 0xFF);
      final path1 = writeStyleFile(bytes, name: 'one.jpg');
      final path2 = writeStyleFile(bytes, name: 'two.jpg');
      int calls = 0;
      await cache.getOrCompute(
        stylePath: path1,
        compute: () async {
          calls++;
          return fakeVector();
        },
      );
      await cache.getOrCompute(
        stylePath: path2,
        compute: () async {
          calls++;
          return fakeVector(100, 0.5);
        },
      );
      expect(calls, 1,
          reason: 'content-keyed cache: copying the reference image '
              'under a new path still hits the same sha');
    });

    test('different bytes → different sha → both compute', () async {
      final cache = StyleVectorCache(rootOverride: tmp);
      final a = writeStyleFile(const [1, 2, 3], name: 'a.jpg');
      final b = writeStyleFile(const [4, 5, 6], name: 'b.jpg');
      int calls = 0;
      await cache.getOrCompute(
        stylePath: a,
        compute: () async {
          calls++;
          return fakeVector();
        },
      );
      await cache.getOrCompute(
        stylePath: b,
        compute: () async {
          calls++;
          return fakeVector();
        },
      );
      expect(calls, 2);
      expect(cache.debugComputeCallCount, 2);
      expect(cache.debugCacheHitCount, 0);
    });

    test('cache-miss survives a new cache instance (cross-session reuse)',
        () async {
      // First session — warms the disk.
      final first = StyleVectorCache(rootOverride: tmp);
      final path = writeStyleFile(const [7, 7, 7, 7]);
      int calls = 0;
      await first.getOrCompute(
        stylePath: path,
        compute: () async {
          calls++;
          return fakeVector();
        },
      );
      expect(calls, 1);
      // Second session — fresh cache, same disk.
      final second = StyleVectorCache(rootOverride: tmp);
      await second.getOrCompute(
        stylePath: path,
        compute: () async {
          calls++;
          return fakeVector();
        },
      );
      expect(calls, 1,
          reason: 'across-instance reuse is the V.5 headline win');
      expect(second.debugCacheHitCount, 1);
      expect(second.debugComputeCallCount, 0);
    });

    test('compute throwing does NOT poison the cache', () async {
      final cache = StyleVectorCache(rootOverride: tmp);
      final path = writeStyleFile(const [1, 1, 1]);
      await expectLater(
        cache.getOrCompute(
          stylePath: path,
          compute: () async => throw StateError('boom'),
        ),
        throwsA(isA<StateError>()),
      );
      // Retry with a working compute succeeds — nothing cached from
      // the failed attempt.
      int calls = 0;
      final out = await cache.getOrCompute(
        stylePath: path,
        compute: () async {
          calls++;
          return fakeVector();
        },
      );
      expect(calls, 1);
      expect(out.length, 100);
    });

    test('load can see what store wrote, before any getOrCompute ran',
        () async {
      final cache = StyleVectorCache(rootOverride: tmp);
      final v = fakeVector();
      await cache.store('manual', v);
      final loaded = await cache.load('manual');
      expect(loaded, isNotNull);
      expect(loaded![42], closeTo(v[42], 1e-6));
      expect(cache.debugComputeCallCount, 0);
      expect(cache.debugCacheHitCount, 0,
          reason: 'direct load/store do NOT touch the cache counters');
    });
  });

  group('StyleVectorCache file layout', () {
    test('writes under rootOverride/<sha>.bin', () async {
      final cache = StyleVectorCache(rootOverride: tmp);
      final path = writeStyleFile(const [4, 2]);
      await cache.getOrCompute(
        stylePath: path,
        compute: () async => fakeVector(),
      );
      final files = tmp
          .listSync()
          .whereType<File>()
          .where((f) => f.path.endsWith('.bin'))
          .toList();
      expect(files, hasLength(1));
      expect(files.first.path, endsWith('.bin'));
      // 100 float32 = 400 bytes exactly.
      expect(files.first.lengthSync(), 400);
    });
  });
}
