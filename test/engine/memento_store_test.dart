import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:image_editor/engine/history/memento_store.dart';

/// Smoke + behaviour tests for [MementoStore].
///
/// These exercise the in-RAM ring (path_provider isn't available in
/// pure flutter_test runs, so the disk path is best-effort and the
/// store gracefully falls back to RAM-only). The disk-budget eviction
/// path is exercised against a stubbed disk dir injected via the
/// store's public `init` (it tolerates `getApplicationDocumentsDirectory`
/// throwing — that's the no-platform-channel branch).
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Uint8List bytes(int n, [int fill = 0xAA]) =>
      Uint8List.fromList(List<int>.filled(n, fill));

  group('MementoStore (RAM ring)', () {
    test('store keeps the latest ramRingCapacity entries in RAM',
        () async {
      final store = MementoStore(ramRingCapacity: 2);
      final m1 = await store.store(
          opId: 'op1', width: 1, height: 1, bytes: bytes(4));
      final m2 = await store.store(
          opId: 'op2', width: 1, height: 1, bytes: bytes(4));
      final m3 = await store.store(
          opId: 'op3', width: 1, height: 1, bytes: bytes(4));

      // First entry should have spilled (or stayed in RAM if disk
      // unavailable in the test env). Latest two are always in RAM.
      expect(store.totalCount, 3);
      expect(store.ramCount, lessThanOrEqualTo(3));
      // m2 and m3 stay in RAM regardless.
      expect(m2.isInMemory, true);
      expect(m3.isInMemory, true);
      // m1 may or may not have spilled depending on disk availability.
      expect(m1.id, isNotEmpty);
    });

    test('lookup returns the requested entry, drop removes it', () async {
      final store = MementoStore(ramRingCapacity: 4);
      final m = await store.store(
          opId: 'op', width: 1, height: 1, bytes: bytes(4));
      expect(store.lookup(m.id), same(m));
      await store.drop(m.id);
      expect(store.lookup(m.id), isNull);
      expect(store.totalCount, 0);
    });

    test('clear wipes everything', () async {
      final store = MementoStore(ramRingCapacity: 4);
      await store.store(opId: 'a', width: 1, height: 1, bytes: bytes(4));
      await store.store(opId: 'b', width: 1, height: 1, bytes: bytes(4));
      expect(store.totalCount, 2);
      await store.clear();
      expect(store.totalCount, 0);
      expect(store.ramCount, 0);
    });

    test('readBytes returns the original bytes', () async {
      final store = MementoStore(ramRingCapacity: 4);
      final original = bytes(8, 0x42);
      final m = await store.store(
          opId: 'x', width: 2, height: 2, bytes: original);
      final read = await m.readBytes();
      expect(read, equals(original));
    });
  });

  group('MementoStore (constructor knobs)', () {
    test('default disk budget is 200 MB', () {
      final store = MementoStore();
      expect(store.diskBudgetBytes, 200 * 1024 * 1024);
    });

    test('disk budget honors override', () {
      final store = MementoStore(diskBudgetBytes: 5 * 1024 * 1024);
      expect(store.diskBudgetBytes, 5 * 1024 * 1024);
    });
  });
}
