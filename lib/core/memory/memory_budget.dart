import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/foundation.dart';

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
  final int maxRamMementos;

  /// Fallback for hosts where DeviceInfoPlus cannot determine RAM.
  static const MemoryBudget conservative = MemoryBudget(
    totalPhysicalRamBytes: 0,
    imageCacheMaxBytes: 192 * 1024 * 1024, // 192 MB
    previewLongEdge: 1920,
    maxRamMementos: 3,
  );

  /// Probe the device and return a [MemoryBudget] tuned to its RAM.
  static Future<MemoryBudget> probe() async {
    try {
      final info = DeviceInfoPlugin();
      int ram = 0;
      if (defaultTargetPlatform == TargetPlatform.android) {
        final android = await info.androidInfo;
        // physicalRamSize is in MB on newer plugin versions; tolerate missing.
        // ignore: invalid_use_of_visible_for_testing_member
        final raw = (android.data['physicalRamSize'] as num?)?.toInt();
        if (raw != null && raw > 0) {
          ram = raw * 1024 * 1024;
        }
      } else if (defaultTargetPlatform == TargetPlatform.iOS) {
        final ios = await info.iosInfo;
        final raw = (ios.data['totalRam'] as num?)?.toInt();
        if (raw != null && raw > 0) {
          ram = raw; // iOS reports in bytes
        }
      }
      if (ram <= 0) return conservative;

      // 1/8 of RAM for image cache, capped at 512 MB.
      final cacheBytes = (ram ~/ 8).clamp(64 * 1024 * 1024, 512 * 1024 * 1024);
      // Scale preview long edge with device RAM.
      final long = ram < 3 * 1024 * 1024 * 1024
          ? 1440
          : ram < 6 * 1024 * 1024 * 1024
              ? 1920
              : 2560;
      return MemoryBudget(
        totalPhysicalRamBytes: ram,
        imageCacheMaxBytes: cacheBytes,
        previewLongEdge: long,
        maxRamMementos: 3,
      );
    } catch (_) {
      return conservative;
    }
  }
}
