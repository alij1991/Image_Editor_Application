import 'package:flutter_test/flutter_test.dart';

import 'package:image_editor/features/scanner/domain/models/scan_models.dart';
import 'package:image_editor/features/scanner/infrastructure/classical_corner_seed.dart';

/// Phase V.9 tests for the default `CornerSeeder.seedBatch` surface.
///
/// The OpenCV-specific compute()-backed batch path exercises real
/// FFI and needs fixture images on disk — that coverage lives in
/// `scanner_smoke_test.dart` via `ScannerNotifier`, which already
/// runs under platform channels. These tests pin the interface-level
/// invariants the V.9 design requires:
///
///   1. Default `seedBatch` preserves order (result[i] ↔ input[i]).
///   2. Default `seedBatch` calls `seed` exactly once per path.
///   3. Empty input returns empty output with zero seed calls.
///   4. The default impl propagates exceptions from the underlying
///      `seed` — callers that want "soft" batching wrap their own
///      try/catch (see `OpenCvCornerSeed.seedBatch` which does this).
void main() {
  group('CornerSeeder.seedBatch — default sequential behavior', () {
    test('empty input → empty output, zero seed calls', () async {
      int seedCalls = 0;
      final seeder = _FakeSeeder((path) {
        seedCalls++;
        return SeedResult(corners: Corners.inset(), fellBack: false);
      });
      final results = await seeder.seedBatch(const []);
      expect(results, isEmpty);
      expect(seedCalls, 0);
    });

    test('calls seed exactly once per path, preserving order', () async {
      final seenOrder = <String>[];
      final seeder = _FakeSeeder((path) {
        seenOrder.add(path);
        // Use the 'tl' corner to carry the path index back out so
        // test assertions can verify ordering.
        final idx = path.codeUnits.last - 48; // last char as int
        return SeedResult(
          corners: Corners(
            Point2(idx / 10.0, 0),
            const Point2(1, 0),
            const Point2(1, 1),
            const Point2(0, 1),
          ),
          fellBack: false,
        );
      });
      final results = await seeder.seedBatch(const ['/a/0', '/b/1', '/c/2']);
      expect(seenOrder, ['/a/0', '/b/1', '/c/2']);
      expect(results, hasLength(3));
      expect(results[0].corners.tl.x, closeTo(0.0, 1e-6));
      expect(results[1].corners.tl.x, closeTo(0.1, 1e-6));
      expect(results[2].corners.tl.x, closeTo(0.2, 1e-6));
    });

    test('preserves fellBack per-result', () async {
      int call = 0;
      final seeder = _FakeSeeder((_) {
        final fell = call.isEven;
        call++;
        return SeedResult(corners: Corners.inset(), fellBack: fell);
      });
      final results = await seeder.seedBatch(const ['/0', '/1', '/2', '/3']);
      expect(results.map((r) => r.fellBack).toList(), [true, false, true, false]);
    });

    test('propagates the underlying seed exception', () async {
      final seeder = _FakeSeeder((path) {
        if (path == '/boom') throw StateError('bad path');
        return SeedResult(corners: Corners.inset(), fellBack: false);
      });
      await expectLater(
        seeder.seedBatch(const ['/ok', '/boom']),
        throwsA(isA<StateError>()),
      );
    });

    test('single-path batch returns one result', () async {
      int calls = 0;
      final seeder = _FakeSeeder((_) {
        calls++;
        return SeedResult(corners: Corners.inset(), fellBack: false);
      });
      final results = await seeder.seedBatch(const ['/solo']);
      expect(results, hasLength(1));
      expect(calls, 1);
    });
  });

  group('ClassicalCornerSeed seedBatch — default forwarder override', () {
    test('empty input returns empty', () async {
      const seeder = ClassicalCornerSeed();
      final results = await seeder.seedBatch(const []);
      expect(results, isEmpty);
    });
  });
}

/// Minimal fake that routes every `seed` through an injected closure.
/// Uses the default `seedBatch` sequential forwarder defined on
/// `CornerSeeder` — implementers are required by the Dart `implements`
/// contract to provide a matching signature.
class _FakeSeeder implements CornerSeeder {
  _FakeSeeder(this.onSeed);
  final SeedResult Function(String path) onSeed;

  @override
  Future<SeedResult> seed(String imagePath) async => onSeed(imagePath);

  @override
  Future<List<SeedResult>> seedBatch(List<String> imagePaths) async {
    final results = <SeedResult>[];
    for (final path in imagePaths) {
      results.add(await seed(path));
    }
    return results;
  }
}
