import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/foundation.dart';

import '../logging/app_logger.dart';

final _log = AppLogger('MemoryBudget');

/// Per-device RAM budget calculator.
///
/// The blueprint flags Impeller issue #178264 (GPU memory ballooning to
/// 3.5 GB on some Android builds) and a 20 MP image at 75 MB as the two
/// primary memory pressure sources. We respond by:
///
/// 1. Limiting `PaintingBinding.imageCache.maximumSizeBytes` to 1/8 of
///    total physical RAM.
/// 2. Downscaling previews to screen-size proxies.
/// 3. Spilling mementos to disk once a threshold is crossed.
///
/// [MemoryBudget.probe] asynchronously queries device info and returns a
/// populated [MemoryBudget]. Call it once at app start and store the
/// result in a global constant / provider.
class MemoryBudget {
  const MemoryBudget({
    required this.totalPhysicalRamBytes,
    required this.imageCacheMaxBytes,
    required this.previewLongEdge,
    required this.maxRamMementos,
    required this.maxProxyEntries,
  });

  /// Approximate total physical RAM on the device in bytes. May be 0 if
  /// the platform refuses to report (older Android, iOS).
  final int totalPhysicalRamBytes;

  /// Cap for `PaintingBinding.imageCache.maximumSizeBytes`.
  final int imageCacheMaxBytes;

  /// Long-edge pixel target for the preview proxy (per the blueprint's
  /// "decode with cacheWidth set to screen long-edge" guidance).
  final int previewLongEdge;

  /// Maximum number of Memento snapshots the in-RAM ring will hold before
  /// spilling to disk.
  ///
  /// Phase V.2: RAM-tiered instead of the old flat `3`.
  /// See [fromRam] for the thresholds.
  final int maxRamMementos;

  /// Maximum number of decoded [PreviewProxy] entries the editor-wide
  /// LRU cache keeps in memory.
  ///
  /// Phase V.2: RAM-tiered. Holding more proxies shortens "re-open a
  /// previously-edited image" latency at the cost of decoded-image
  /// GPU/RAM residency. At the 1920 long-edge baseline a proxy
  /// weighs ~30 MB, so 8 entries ≈ 240 MB — fits a 12 GB-class
  /// device comfortably.
  final int maxProxyEntries;

  /// Fallback for hosts where DeviceInfoPlus cannot determine RAM.
  /// Phase V.2 keeps `maxRamMementos` + `maxProxyEntries` at 3 for
  /// the conservative tier — matches the pre-V.2 hard-coded default.
  static const MemoryBudget conservative = MemoryBudget(
    totalPhysicalRamBytes: 0,
    imageCacheMaxBytes: 192 * 1024 * 1024, // 192 MB
    previewLongEdge: 1920,
    maxRamMementos: 3,
    maxProxyEntries: 3,
  );

  /// Phase V.2: pure helper that maps [ramBytes] to a tuned
  /// [MemoryBudget]. Extracted from [probe] so the per-tier scaling
  /// is unit-testable without mocking the device_info_plus plugin.
  ///
  /// Tiers (inclusive lower / exclusive upper):
  /// - **< 3 GB** — low-end: `maxRamMementos=3`, `maxProxyEntries=3`,
  ///   preview=1440
  /// - **< 6 GB** — mid-range: `maxRamMementos=5`,
  ///   `maxProxyEntries=5`, preview=1920
  /// - **≥ 6 GB** — high-end: `maxRamMementos=8`,
  ///   `maxProxyEntries=8`, preview=2560
  ///
  /// `imageCacheMaxBytes` is always `ram / 8`, clamped to
  /// [64 MB, 512 MB]. `ramBytes <= 0` returns [conservative].
  @visibleForTesting
  static MemoryBudget fromRam(int ramBytes) {
    if (ramBytes <= 0) return conservative;

    // 1/8 of RAM for image cache, clamped to [64 MB, 512 MB].
    final cacheBytes =
        (ramBytes ~/ 8).clamp(64 * 1024 * 1024, 512 * 1024 * 1024);

    const gb = 1024 * 1024 * 1024;
    final int long;
    final int mementos;
    final int proxies;
    if (ramBytes < 3 * gb) {
      long = 1440;
      mementos = 3;
      proxies = 3;
    } else if (ramBytes < 6 * gb) {
      long = 1920;
      mementos = 5;
      proxies = 5;
    } else {
      long = 2560;
      mementos = 8;
      proxies = 8;
    }

    return MemoryBudget(
      totalPhysicalRamBytes: ramBytes,
      imageCacheMaxBytes: cacheBytes,
      previewLongEdge: long,
      maxRamMementos: mementos,
      maxProxyEntries: proxies,
    );
  }

  /// Probe the device and return a [MemoryBudget] tuned to its RAM.
  ///
  /// **Phase V.10**: the RAM-extraction step was moved into a pure,
  /// test-injectable helper — [extractRamBytes] — so a mock-provider
  /// unit test can pin the exact shape of the per-platform data map
  /// the app depends on. `device_info_plus` exposes platform RAM via
  /// its loosely-typed `.data` map (no typed accessor as of 10.1.2),
  /// so a silent upstream key rename would degrade every device to
  /// [conservative]. The extraction now emits a WARNING log when the
  /// expected key is absent from a non-empty data map — turning a
  /// silent regression into a noisy one.
  static Future<MemoryBudget> probe() async {
    try {
      final info = DeviceInfoPlugin();
      Map<String, dynamic> data = const <String, dynamic>{};
      if (defaultTargetPlatform == TargetPlatform.android) {
        data = (await info.androidInfo).data;
      } else if (defaultTargetPlatform == TargetPlatform.iOS) {
        data = (await info.iosInfo).data;
      }
      final ram = extractRamBytes(
        platform: defaultTargetPlatform,
        data: data,
      );
      return fromRam(ram);
    } catch (e) {
      _log.w('probe failed, falling back to conservative',
          {'error': e.toString()});
      return conservative;
    }
  }

  /// Phase V.10: extract physical RAM (bytes) from a platform's
  /// [device_info_plus] data map. Pure helper so [probe] is
  /// unit-testable without mocking the platform channel.
  ///
  /// Key contract (what this method reads):
  ///   - `TargetPlatform.android` → `data['physicalRamSize']` in MB
  ///     (name mirrors `android.app.ActivityManager.MemoryInfo`).
  ///   - `TargetPlatform.iOS`     → `data['totalRam']` in bytes.
  ///
  /// When the expected key is absent from a non-empty data map,
  /// logs a WARNING. This is the V.10 safety net: a silent
  /// fallback to [conservative] across every device would be
  /// near-invisible in field telemetry; a WARNING line flags
  /// the regression immediately.
  ///
  /// Returns `0` when the platform isn't supported, the data is
  /// empty, the key is missing, or the value is non-positive.
  /// [probe] then routes `0` into [conservative] via [fromRam].
  @visibleForTesting
  static int extractRamBytes({
    required TargetPlatform platform,
    required Map<String, dynamic> data,
  }) {
    if (platform == TargetPlatform.android) {
      final raw = (data['physicalRamSize'] as num?)?.toInt();
      if (raw != null && raw > 0) return raw * 1024 * 1024;
      if (data.isNotEmpty) {
        _log.w(
          'android data map missing physicalRamSize — key may have '
          'been renamed in device_info_plus; falling back to conservative',
          {'keys': data.keys.toList()},
        );
      }
      return 0;
    }
    if (platform == TargetPlatform.iOS) {
      final raw = (data['totalRam'] as num?)?.toInt();
      if (raw != null && raw > 0) return raw;
      if (data.isNotEmpty) {
        _log.w(
          'ios data map missing totalRam — key may have been renamed '
          'in device_info_plus; falling back to conservative',
          {'keys': data.keys.toList()},
        );
      }
      return 0;
    }
    return 0;
  }
}
