import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

import 'package:image_editor/engine/history/memento_store.dart';

/// X.B.2 — the disk-budget eviction used to be oldest-first regardless
/// of size. A user with 20 × 2 MB drawings preceding a 50 MB super-res
/// would lose every drawing before the super-res got touched. Post-
/// X.B.2 the largest entry goes first, reclaiming budget in one
/// eviction and preserving many small undo targets.
///
/// Two layers of coverage:
///   1. `pickDiskEvictionOrder` pure-function tests — pin the sort.
///   2. End-to-end `_enforceDiskBudget` via a mocked `path_provider`
///      so the real filesystem path executes (catches any drift
///      between the pure helper and the I/O loop).
class _TmpPathProvider extends PathProviderPlatform
    with MockPlatformInterfaceMixin {
  _TmpPathProvider(this.tmp);
  final String tmp;
  @override
  Future<String?> getApplicationDocumentsPath() async => tmp;
  @override
  Future<String?> getTemporaryPath() async => tmp;
  @override
  Future<String?> getApplicationSupportPath() async => tmp;
  @override
  Future<String?> getApplicationCachePath() async => tmp;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Uint8List bytes(int n, [int fill = 0xAA]) =>
      Uint8List.fromList(List<int>.filled(n, fill));

  // _FakeMemento that pickDiskEvictionOrder only cares about as an
  // identity-bearing reference — nothing else from Memento is read.
  Memento fakeMemento(String id) {
    return Memento(
      id: id,
      opId: 'op_$id',
      width: 1,
      height: 1,
      inMemory: bytes(1),
    );
  }

  group('pickDiskEvictionOrder (pure)', () {
    test('largest comes out first', () {
      final small = fakeMemento('small');
      final huge = fakeMemento('huge');
      final mid = fakeMemento('mid');
      final order = pickDiskEvictionOrder([
        (small, 2 * 1024 * 1024),
        (huge, 50 * 1024 * 1024),
        (mid, 10 * 1024 * 1024),
      ]);
      expect(order.map((m) => m.id).toList(), ['huge', 'mid', 'small']);
    });

    test('ties on size break by insertion order (oldest first)', () {
      final a = fakeMemento('a');
      final b = fakeMemento('b');
      final c = fakeMemento('c');
      final order = pickDiskEvictionOrder([
        (a, 10),
        (b, 10),
        (c, 10),
      ]);
      expect(order.map((m) => m.id).toList(), ['a', 'b', 'c'],
          reason: 'uniform sizes must fall back to ring-insertion order');
    });

    test('mixed tie groups preserve tie order within each size bucket', () {
      // Two 50 MB entries (oldest first) then two 10 MB (oldest first).
      final big1 = fakeMemento('big1');
      final small1 = fakeMemento('small1');
      final big2 = fakeMemento('big2');
      final small2 = fakeMemento('small2');
      final order = pickDiskEvictionOrder([
        (big1, 50),
        (small1, 10),
        (big2, 50),
        (small2, 10),
      ]);
      expect(order.map((m) => m.id).toList(),
          ['big1', 'big2', 'small1', 'small2']);
    });

    test('empty input yields empty output', () {
      expect(pickDiskEvictionOrder([]), isEmpty);
    });

    test('single entry is returned as-is', () {
      final m = fakeMemento('only');
      expect(pickDiskEvictionOrder([(m, 42)]).map((x) => x.id).toList(),
          ['only']);
    });
  });

  group('MementoStore._enforceDiskBudget (end-to-end)', () {
    late Directory tmp;

    setUp(() {
      tmp = Directory.systemTemp.createTempSync('memento_size_evict');
      PathProviderPlatform.instance = _TmpPathProvider(tmp.path);
    });

    tearDown(() {
      if (tmp.existsSync()) tmp.deleteSync(recursive: true);
    });

    test(
        'one giant + many small: budget breach evicts the giant, small survive',
        () async {
      // Budget 100 KB. Layout in ring order:
      //   5× 2 KB smalls (drawings) → total 10 KB
      //   1× 100 KB giant (super-res) → running total 110 KB, over cap.
      // Pre-X.B.2 (oldest-first) would have evicted all 5 smalls → 100 KB
      // remaining (still over by 0; actually right at cap so stop).
      // Post-X.B.2 (largest-first) evicts the one giant → 10 KB
      // remaining; 5 smalls survive.
      final store = MementoStore(
        ramRingCapacity: 1, // force the oldest entries to spill
        diskBudgetBytes: 100 * 1024,
      );

      // Seed 5 small mementos (each 2 KB).
      final smalls = <String>[];
      for (var i = 0; i < 5; i++) {
        final m = await store.store(
          opId: 'small$i',
          width: 1,
          height: 1,
          bytes: bytes(2 * 1024, i),
        );
        smalls.add(m.id);
      }
      // Push a 100 KB giant — triggers budget enforcement on next
      // store because ramRingCapacity=1 spills the giant itself? No,
      // the giant becomes the newest RAM tenant. The previous newest
      // spills. Total on disk after this call = 10 KB (5×2KB). Still
      // under budget.
      await store.store(
        opId: 'giant',
        width: 1,
        height: 1,
        bytes: bytes(100 * 1024, 0xFF),
      );
      // One more store to force the giant onto disk. The spill order
      // is insertion-oldest-first, so this puts the giant on disk too.
      final trigger = await store.store(
        opId: 'trigger',
        width: 1,
        height: 1,
        bytes: bytes(512, 0x11),
      );

      // After the trigger store + enforce cycle: the disk holds
      // [5 smalls, giant] sum = 110 KB → over budget. Evict largest
      // first → drop the giant → 10 KB remaining. All 5 smalls are
      // retrievable; the giant is gone.
      expect(store.lookup(trigger.id), isNotNull);
      for (final id in smalls) {
        expect(store.lookup(id), isNotNull,
            reason: 'small $id should survive size-aware eviction');
      }
      // Find the giant by opId; it should be gone.
      expect(
        store.totalCount,
        6,
        reason: 'started with 7 (5 smalls + giant + trigger) — 1 evicted',
      );
    });

    test('uniform-size over-budget falls back to oldest-first', () async {
      // All 5 entries are 40 KB each; budget 100 KB → only 2 fit on
      // disk. Drops oldest-first among ties — the first 3 get evicted
      // on the 5th store. (ramRingCapacity=1 so 4 of 5 are on disk.)
      final store = MementoStore(
        ramRingCapacity: 1,
        diskBudgetBytes: 100 * 1024,
      );
      final ids = <String>[];
      for (var i = 0; i < 5; i++) {
        final m = await store.store(
          opId: 'op$i',
          width: 1,
          height: 1,
          bytes: bytes(40 * 1024, i),
        );
        ids.add(m.id);
      }
      // The newest (5th) is in RAM; the previous 4 spilled. Disk sum
      // was 4 × 40 = 160 KB → over 100 KB by 60 KB. Evicting the
      // oldest 2 (at 40 KB each) brings disk to 80 KB.
      //
      // Result: the 2 oldest on disk are gone, the 2 newer on disk +
      // the 1 in RAM survive.
      expect(store.lookup(ids[0]), isNull,
          reason: 'oldest tie should evict first');
      expect(store.lookup(ids[1]), isNull,
          reason: 'second-oldest tie should evict second');
      expect(store.lookup(ids[2]), isNotNull);
      expect(store.lookup(ids[3]), isNotNull);
      expect(store.lookup(ids[4]), isNotNull);
    });
  });
}
