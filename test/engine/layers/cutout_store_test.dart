import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:image_editor/engine/layers/cutout_store.dart';

/// Behaviour tests for [CutoutStore].
///
/// Focus: the Phase I.9 persistence contract — cutouts must survive a
/// simulated session close by landing on disk where the NEXT session
/// can read them. Also covers eviction under the 200 MB budget so a
/// long-running user can't fill their disk with cached AI bitmaps.
void main() {
  late Directory tmp;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('cutout_store_test');
  });

  tearDown(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  Uint8List bytesOfSize(int n, {int seed = 0}) {
    final out = Uint8List(n);
    for (var i = 0; i < n; i++) {
      out[i] = (i * 31 + seed) & 0xFF;
    }
    return out;
  }

  group('CutoutStore round-trip', () {
    test('put → get returns the same bytes', () async {
      final store = CutoutStore(rootOverride: tmp);
      final bytes = bytesOfSize(4096);

      await store.put(
        sourcePath: '/photos/cat.jpg',
        layerId: 'layer-42',
        pngBytes: bytes,
      );

      final loaded = await store.get(
        sourcePath: '/photos/cat.jpg',
        layerId: 'layer-42',
      );
      expect(loaded, isNotNull);
      expect(loaded!.length, bytes.length);
      expect(loaded, equals(bytes));
    });

    test('get returns null when nothing has been stored', () async {
      final store = CutoutStore(rootOverride: tmp);
      final loaded = await store.get(
        sourcePath: '/never/written.jpg',
        layerId: 'ghost',
      );
      expect(loaded, isNull);
    });

    test('put twice for the same (sourcePath, layerId) overwrites',
        () async {
      final store = CutoutStore(rootOverride: tmp);
      const src = '/photos/overwrite.jpg';
      const lid = 'layer-1';

      await store.put(
          sourcePath: src, layerId: lid, pngBytes: bytesOfSize(256, seed: 1));
      await store.put(
          sourcePath: src, layerId: lid, pngBytes: bytesOfSize(512, seed: 2));

      final loaded = await store.get(sourcePath: src, layerId: lid);
      expect(loaded, isNotNull);
      expect(loaded!.length, 512);
      expect(loaded[0], 2 & 0xFF);
    });

    test('simulated session close: a fresh store reads back the file',
        () async {
      // Session 1 persists a cutout.
      {
        final store = CutoutStore(rootOverride: tmp);
        await store.put(
          sourcePath: '/photos/p.jpg',
          layerId: 'layer-xyz',
          pngBytes: bytesOfSize(1024),
        );
      }
      // Session 2 gets a brand-new store instance pointed at the same
      // root — this is what actually happens when the user reopens
      // the editor.
      final reopened = CutoutStore(rootOverride: tmp);
      final loaded = await reopened.get(
        sourcePath: '/photos/p.jpg',
        layerId: 'layer-xyz',
      );
      expect(loaded, isNotNull,
          reason: 'cutouts must survive a session boundary — '
              'losing them is exactly the bug Phase I.9 fixes');
      expect(loaded!.length, 1024);
    });
  });

  group('CutoutStore bucket layout', () {
    test('different source paths produce different buckets', () async {
      final store = CutoutStore(rootOverride: tmp);
      final a = store.bucketFor('/photos/one.jpg');
      final b = store.bucketFor('/photos/two.jpg');
      expect(a, isNot(equals(b)));
    });

    test('same source path produces a stable bucket across instances', () {
      final s1 = CutoutStore(rootOverride: tmp);
      final s2 = CutoutStore(rootOverride: tmp);
      const src = '/photos/stable.jpg';
      expect(s1.bucketFor(src), equals(s2.bucketFor(src)));
    });

    test('two projects with the same layerId do not collide', () async {
      final store = CutoutStore(rootOverride: tmp);
      const lid = 'shared-id';

      await store.put(
          sourcePath: '/a/cat.jpg',
          layerId: lid,
          pngBytes: bytesOfSize(100, seed: 1));
      await store.put(
          sourcePath: '/b/dog.jpg',
          layerId: lid,
          pngBytes: bytesOfSize(100, seed: 2));

      final fromA = await store.get(sourcePath: '/a/cat.jpg', layerId: lid);
      final fromB = await store.get(sourcePath: '/b/dog.jpg', layerId: lid);

      expect(fromA, isNotNull);
      expect(fromB, isNotNull);
      expect(fromA![0], isNot(fromB![0]),
          reason: 'projects with the same layer id must stay isolated');
    });
  });

  group('CutoutStore delete', () {
    test('delete removes one cutout', () async {
      final store = CutoutStore(rootOverride: tmp);
      const src = '/photos/del.jpg';
      const lid = 'del-layer';
      await store.put(
          sourcePath: src, layerId: lid, pngBytes: bytesOfSize(64));
      expect(await store.get(sourcePath: src, layerId: lid), isNotNull);

      await store.delete(sourcePath: src, layerId: lid);
      expect(await store.get(sourcePath: src, layerId: lid), isNull);
    });

    test('delete of a missing cutout is a no-op (no throw)', () async {
      final store = CutoutStore(rootOverride: tmp);
      await store.delete(sourcePath: '/none', layerId: 'ghost');
      // If we got here, no throw.
    });

    test('deleteProject removes every cutout in that project', () async {
      final store = CutoutStore(rootOverride: tmp);
      const src = '/photos/project.jpg';
      await store.put(
          sourcePath: src, layerId: 'l1', pngBytes: bytesOfSize(128));
      await store.put(
          sourcePath: src, layerId: 'l2', pngBytes: bytesOfSize(256));
      expect(await store.get(sourcePath: src, layerId: 'l1'), isNotNull);
      expect(await store.get(sourcePath: src, layerId: 'l2'), isNotNull);

      await store.deleteProject(src);
      expect(await store.get(sourcePath: src, layerId: 'l1'), isNull);
      expect(await store.get(sourcePath: src, layerId: 'l2'), isNull);
    });

    test('deleteProject leaves other projects intact', () async {
      final store = CutoutStore(rootOverride: tmp);
      await store.put(
          sourcePath: '/a.jpg', layerId: 'l', pngBytes: bytesOfSize(64));
      await store.put(
          sourcePath: '/b.jpg', layerId: 'l', pngBytes: bytesOfSize(64));

      await store.deleteProject('/a.jpg');

      expect(await store.get(sourcePath: '/a.jpg', layerId: 'l'), isNull);
      expect(await store.get(sourcePath: '/b.jpg', layerId: 'l'), isNotNull,
          reason: 'deleteProject must only drop its own bucket');
    });
  });

  group('CutoutStore eviction', () {
    test('totalBytes reports the on-disk size', () async {
      final store = CutoutStore(rootOverride: tmp);
      expect(await store.totalBytes(), 0);

      await store.put(
          sourcePath: '/a', layerId: 'x', pngBytes: bytesOfSize(1024));
      expect(await store.totalBytes(), 1024);

      await store.put(
          sourcePath: '/b', layerId: 'y', pngBytes: bytesOfSize(2048));
      expect(await store.totalBytes(), 3072);
    });

    test('evictUntilUnder drops oldest-mtime files first', () async {
      // Tiny budget so the test doesn't have to write 200 MB.
      final store = CutoutStore(rootOverride: tmp, diskBudgetBytes: 5000);
      await store.put(
          sourcePath: '/oldest',
          layerId: 'x',
          pngBytes: bytesOfSize(2000, seed: 1));
      // The filesystem mtime resolution is ~1 s on some platforms.
      // Sleep long enough that the next put lands with a strictly
      // greater mtime — without this, sort order is undefined and the
      // "oldest first" assertion is flaky.
      await Future<void>.delayed(const Duration(seconds: 1));
      await store.put(
          sourcePath: '/newest',
          layerId: 'y',
          pngBytes: bytesOfSize(2000, seed: 2));

      // Total is 4000 — still under 5000 budget, nothing evicted yet.
      expect(await store.totalBytes(), 4000);

      // Ask for a tighter trim; only the oldest one should go.
      final evicted = await store.evictUntilUnder(2500);
      expect(evicted, 1);
      expect(await store.get(sourcePath: '/oldest', layerId: 'x'), isNull,
          reason: 'oldest-mtime cutout must be the one evicted first');
      expect(
          await store.get(sourcePath: '/newest', layerId: 'y'), isNotNull);
    });

    test('put auto-trims when it would break the disk budget', () async {
      final store = CutoutStore(rootOverride: tmp, diskBudgetBytes: 1500);
      await store.put(
          sourcePath: '/first',
          layerId: 'x',
          pngBytes: bytesOfSize(1000, seed: 1));
      await Future<void>.delayed(const Duration(seconds: 1));
      await store.put(
          sourcePath: '/second',
          layerId: 'y',
          pngBytes: bytesOfSize(1000, seed: 2));

      // /first + /second = 2000 bytes; budget is 1500. After the
      // second put the auto-evict pass should've dropped /first.
      expect(await store.totalBytes(), lessThanOrEqualTo(1500));
      expect(await store.get(sourcePath: '/first', layerId: 'x'), isNull);
      expect(
          await store.get(sourcePath: '/second', layerId: 'y'), isNotNull);
    });

    test('evictUntilUnder is a no-op when already under budget', () async {
      final store = CutoutStore(rootOverride: tmp, diskBudgetBytes: 1_000_000);
      await store.put(
          sourcePath: '/a', layerId: 'x', pngBytes: bytesOfSize(500));
      final evicted = await store.evictUntilUnder(1_000_000);
      expect(evicted, 0);
      expect(await store.get(sourcePath: '/a', layerId: 'x'), isNotNull);
    });
  });
}
