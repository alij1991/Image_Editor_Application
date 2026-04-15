import 'dart:io';

import '../../../core/logging/app_logger.dart';
import '../domain/models/scan_models.dart';

final _log = AppLogger('ScannerProbe');

/// Runtime capability snapshot used to recommend a detection strategy.
///
/// We keep this cheap — it doesn't actually invoke the scanner, just
/// checks platform and (best-effort) Play Services presence on Android.
class ScannerCapabilities {
  const ScannerCapabilities({
    required this.platform,
    required this.supportsNative,
    required this.supportsOcr,
  });

  final String platform;
  final bool supportsNative;
  final bool supportsOcr;

  /// Pick the strategy the app recommends up front. The user can always
  /// override from the strategy picker dialog.
  DetectorStrategy get recommended {
    if (supportsNative) return DetectorStrategy.native;
    return DetectorStrategy.manual;
  }

  Map<String, dynamic> toJson() => {
        'platform': platform,
        'native': supportsNative,
        'ocr': supportsOcr,
      };
}

class CapabilitiesProbe {
  const CapabilitiesProbe();

  Future<ScannerCapabilities> probe() async {
    final platform = Platform.operatingSystem;
    // cunning_document_scanner wraps ML Kit on Android (needs Play
    // Services) and VisionKit on iOS (needs iOS 13+). We can't cheaply
    // verify Play Services at runtime, so we optimistically enable
    // native on both platforms and let the first call fall through to
    // manual if it throws. That's logged in ScannerNotifier.
    final supportsNative = Platform.isAndroid || Platform.isIOS;
    // ML Kit text recognition runs on both mobile OSes.
    final supportsOcr = Platform.isAndroid || Platform.isIOS;
    final caps = ScannerCapabilities(
      platform: platform,
      supportsNative: supportsNative,
      supportsOcr: supportsOcr,
    );
    _log.i('probe', caps.toJson());
    return caps;
  }
}
