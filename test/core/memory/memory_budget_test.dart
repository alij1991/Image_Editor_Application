import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:image_editor/core/memory/memory_budget.dart';

/// Phase V.2 tests for `MemoryBudget.fromRam` — the pure RAM→tier
/// helper extracted from `probe()` so the device-class scaling is
/// testable without mocking `device_info_plus`.
///
/// The three tiers (low / mid / high) drive the scaling for
/// `maxRamMementos` (undo ring), `maxProxyEntries` (decoded preview
/// LRU), and `previewLongEdge`. These tests pin the exact
/// boundaries — a silent threshold drift on a plugin bump would
/// trip the boundary assertions.
void main() {
  const mb = 1024 * 1024;
  const gb = 1024 * 1024 * 1024;

  group('MemoryBudget.fromRam — device-class tiers', () {
    test('2 GB device lands on the low tier (3 / 3 / 1440)', () {
      final b = MemoryBudget.fromRam(2 * gb);
      expect(b.maxRamMementos, 3);
      expect(b.maxProxyEntries, 3);
      expect(b.previewLongEdge, 1440);
    });

    test('4 GB device lands on the mid tier (5 / 5 / 1920)', () {
      final b = MemoryBudget.fromRam(4 * gb);
      expect(b.maxRamMementos, 5);
      expect(b.maxProxyEntries, 5);
      expect(b.previewLongEdge, 1920);
    });

    test('8 GB device lands on the high tier (8 / 8 / 2560)', () {
      final b = MemoryBudget.fromRam(8 * gb);
      expect(b.maxRamMementos, 8);
      expect(b.maxProxyEntries, 8);
      expect(b.previewLongEdge, 2560);
    });

    test('12 GB device lands on the high tier (8 / 8 / 2560)', () {
      final b = MemoryBudget.fromRam(12 * gb);
      expect(b.maxRamMementos, 8);
      expect(b.maxProxyEntries, 8);
      expect(b.previewLongEdge, 2560);
    });

    test('exact 3 GB boundary is mid-tier (>= 3 GB is mid, < 3 is low)',
        () {
      final b = MemoryBudget.fromRam(3 * gb);
      expect(b.maxRamMementos, 5,
          reason: '3 GB exactly crosses into the mid tier');
      expect(b.maxProxyEntries, 5);
      expect(b.previewLongEdge, 1920);
    });

    test('one byte under 3 GB is low-tier', () {
      final b = MemoryBudget.fromRam(3 * gb - 1);
      expect(b.maxRamMementos, 3);
      expect(b.maxProxyEntries, 3);
      expect(b.previewLongEdge, 1440);
    });

    test('exact 6 GB boundary is high-tier (>= 6 GB is high)', () {
      final b = MemoryBudget.fromRam(6 * gb);
      expect(b.maxRamMementos, 8);
      expect(b.maxProxyEntries, 8);
      expect(b.previewLongEdge, 2560);
    });

    test('one byte under 6 GB is mid-tier', () {
      final b = MemoryBudget.fromRam(6 * gb - 1);
      expect(b.maxRamMementos, 5);
      expect(b.maxProxyEntries, 5);
      expect(b.previewLongEdge, 1920);
    });
  });

  group('MemoryBudget.fromRam — imageCacheMaxBytes scaling', () {
    test('ram/8 for a comfortable 4 GB device (= 512 MB cap)', () {
      // 4 GB / 8 = 512 MB — exactly at the clamp ceiling.
      final b = MemoryBudget.fromRam(4 * gb);
      expect(b.imageCacheMaxBytes, 512 * mb);
    });

    test('ram/8 saturates at 512 MB on a 12 GB device', () {
      final b = MemoryBudget.fromRam(12 * gb);
      // 12 GB / 8 = 1.5 GB → clamped to 512 MB.
      expect(b.imageCacheMaxBytes, 512 * mb);
    });

    test('ram/8 floors at 64 MB on a tiny device', () {
      // 256 MB / 8 = 32 MB → clamped up to 64 MB.
      final b = MemoryBudget.fromRam(256 * mb);
      expect(b.imageCacheMaxBytes, 64 * mb);
      // But RAM is still positive, so we stay out of `conservative`.
      expect(b.totalPhysicalRamBytes, 256 * mb);
    });

    test('1 GB device gets a real slice of RAM for image cache', () {
      final b = MemoryBudget.fromRam(1 * gb);
      // 1 GB / 8 = 128 MB — between floor and ceiling.
      expect(b.imageCacheMaxBytes, 128 * mb);
    });
  });

  group('MemoryBudget.fromRam — conservative fallback', () {
    test('ramBytes == 0 returns the conservative budget', () {
      expect(MemoryBudget.fromRam(0), same(MemoryBudget.conservative));
    });

    test('negative ramBytes returns the conservative budget', () {
      expect(MemoryBudget.fromRam(-1), same(MemoryBudget.conservative));
    });

    test('conservative keeps maxRamMementos=3, maxProxyEntries=3', () {
      // Pins the pre-V.2 default so `probe()` failures don't silently
      // crank the ring sizes up on low-end devices.
      const c = MemoryBudget.conservative;
      expect(c.maxRamMementos, 3);
      expect(c.maxProxyEntries, 3);
      expect(c.previewLongEdge, 1920);
      expect(c.imageCacheMaxBytes, 192 * mb);
      expect(c.totalPhysicalRamBytes, 0,
          reason: 'conservative signals "RAM unknown" with 0');
    });
  });

  group('MemoryBudget — totalPhysicalRamBytes passthrough', () {
    test('result carries the probed RAM value verbatim', () {
      final b = MemoryBudget.fromRam(7 * gb);
      expect(b.totalPhysicalRamBytes, 7 * gb);
    });
  });

  group('MemoryBudget.extractRamBytes — Phase V.10', () {
    test('android: physicalRamSize present → bytes = MB * 1048576', () {
      // device_info_plus reports Android RAM in MiB (via
      // ActivityManager.MemoryInfo). 4096 MB → 4 GB.
      final ram = MemoryBudget.extractRamBytes(
        platform: TargetPlatform.android,
        data: const {'physicalRamSize': 4096, 'manufacturer': 'Test'},
      );
      expect(ram, 4 * gb);
    });

    test('android: physicalRamSize=0 returns 0 (not an error)', () {
      final ram = MemoryBudget.extractRamBytes(
        platform: TargetPlatform.android,
        data: const {'physicalRamSize': 0, 'manufacturer': 'Test'},
      );
      expect(ram, 0);
    });

    test('android: key absent from non-empty data → 0', () {
      // The ABSENCE of physicalRamSize from an otherwise-populated
      // data map is the regression the V.10 safety net guards
      // against — probe() falls back to conservative, extract
      // logs a warning, and the device is downgraded. The
      // unit test doesn't assert on log output but pins the
      // returned-zero contract.
      final ram = MemoryBudget.extractRamBytes(
        platform: TargetPlatform.android,
        data: const {'manufacturer': 'Test', 'model': 'mock'},
      );
      expect(ram, 0);
    });

    test('android: empty data map → 0 with no warning', () {
      // Empty data is "plugin returned nothing useful" — a
      // qualitatively different signal than "populated but key
      // renamed". Both land at conservative, but extract should
      // not log a rename warning for the empty case.
      final ram = MemoryBudget.extractRamBytes(
        platform: TargetPlatform.android,
        data: const {},
      );
      expect(ram, 0);
    });

    test('android: physicalRamSize as double (num) is accepted', () {
      // The data map type is `Map<String, dynamic>`; method-channel
      // serialization can hand a double back even when the upstream
      // is an int. Accept any `num` and truncate.
      final ram = MemoryBudget.extractRamBytes(
        platform: TargetPlatform.android,
        data: const <String, dynamic>{'physicalRamSize': 2048.0},
      );
      expect(ram, 2 * gb);
    });

    test('iOS: totalRam present in bytes is returned verbatim', () {
      final ram = MemoryBudget.extractRamBytes(
        platform: TargetPlatform.iOS,
        data: const {'totalRam': 6 * gb, 'systemName': 'iOS'},
      );
      expect(ram, 6 * gb);
    });

    test('iOS: totalRam=0 returns 0', () {
      final ram = MemoryBudget.extractRamBytes(
        platform: TargetPlatform.iOS,
        data: const {'totalRam': 0, 'systemName': 'iOS'},
      );
      expect(ram, 0);
    });

    test('iOS: key absent from non-empty data → 0 (rename-guard path)',
        () {
      final ram = MemoryBudget.extractRamBytes(
        platform: TargetPlatform.iOS,
        data: const {'name': 'iPhone', 'model': 'iPhone15,2'},
      );
      expect(ram, 0);
    });

    test('iOS: empty data map → 0', () {
      final ram = MemoryBudget.extractRamBytes(
        platform: TargetPlatform.iOS,
        data: const {},
      );
      expect(ram, 0);
    });

    test('unsupported platform returns 0', () {
      // MemoryBudget only supports android + iOS today; desktop
      // probes skip this entire code path. If they ever DO hit
      // extract, they should fall through cleanly to 0.
      final ram = MemoryBudget.extractRamBytes(
        platform: TargetPlatform.linux,
        data: const {'physicalRamSize': 1024},
      );
      expect(ram, 0);
    });

    test('probe via extractRamBytes roundtrips through fromRam correctly',
        () {
      // End-to-end pin: the V.10 probe path constructs the final
      // MemoryBudget by feeding extract's output into fromRam.
      final bytes = MemoryBudget.extractRamBytes(
        platform: TargetPlatform.android,
        data: const {'physicalRamSize': 8192}, // 8 GB
      );
      final b = MemoryBudget.fromRam(bytes);
      expect(b.totalPhysicalRamBytes, 8 * gb);
      expect(b.maxRamMementos, 8,
          reason: '8 GB lands squarely in the high-tier ≥ 6 GB bucket');
      expect(b.maxProxyEntries, 8);
      expect(b.previewLongEdge, 2560);
    });
  });
}
