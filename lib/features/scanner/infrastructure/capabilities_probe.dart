import 'dart:io';

import 'package:flutter/services.dart';

import '../../../core/logging/app_logger.dart';
import '../domain/models/scan_models.dart';

final _log = AppLogger('ScannerProbe');

/// Runtime capability snapshot used to recommend a detection strategy.
///
/// On Android we attempt a real Google Play Services availability check
/// via the standard `com.google.android.gms.common` channel. The check
/// fails open — if the platform side isn't wired up we keep the
/// optimistic `supportsNative = true` and rely on
/// [ScannerUnavailableException] from the first capture call to flip
/// the user into manual mode.
class ScannerCapabilities {
  const ScannerCapabilities({
    required this.platform,
    required this.supportsNative,
    required this.supportsOcr,
    this.nativeUnavailableReason,
  });

  final String platform;
  final bool supportsNative;
  final bool supportsOcr;

  /// Human-readable reason native is unavailable, or null when it is.
  /// Surfaced in the strategy picker so the user understands why
  /// "Native scanner" is greyed out.
  final String? nativeUnavailableReason;

  /// Pick the strategy the app recommends up front. The user can always
  /// override from the strategy picker dialog.
  DetectorStrategy get recommended {
    if (supportsNative) return DetectorStrategy.native;
    return DetectorStrategy.auto;
  }

  Map<String, dynamic> toJson() => {
        'platform': platform,
        'native': supportsNative,
        'ocr': supportsOcr,
        if (nativeUnavailableReason != null)
          'why': nativeUnavailableReason,
      };
}

class CapabilitiesProbe {
  const CapabilitiesProbe();

  static const _playServicesChannel =
      MethodChannel('com.imageeditor/play_services');

  Future<ScannerCapabilities> probe() async {
    final platform = Platform.operatingSystem;
    var supportsNative = Platform.isAndroid || Platform.isIOS;
    String? reason;

    if (Platform.isAndroid) {
      try {
        // Returns one of the GoogleApiAvailability result codes:
        //   0 = success, 1 = service missing, 2 = update required,
        //   3 = disabled, 9 = invalid, 18 = updating, ...
        final code = await _playServicesChannel
            .invokeMethod<int>('checkAvailability')
            .timeout(const Duration(milliseconds: 800));
        if (code != null && code != 0) {
          supportsNative = false;
          reason = _playServicesReasonFor(code);
        }
      } on MissingPluginException {
        // Channel not implemented yet — keep the optimistic default.
        _log.d('play services channel unwired, optimistic');
      } catch (e) {
        _log.w('play services probe failed', {'err': e.toString()});
      }
    }

    final supportsOcr = Platform.isAndroid || Platform.isIOS;
    final caps = ScannerCapabilities(
      platform: platform,
      supportsNative: supportsNative,
      supportsOcr: supportsOcr,
      nativeUnavailableReason: reason,
    );
    _log.i('probe', caps.toJson());
    return caps;
  }

  String _playServicesReasonFor(int code) {
    switch (code) {
      case 1:
        return 'Google Play Services is missing on this device.';
      case 2:
        return 'Google Play Services needs updating to use the native scanner.';
      case 3:
        return 'Google Play Services is disabled on this device.';
      case 9:
        return 'Google Play Services is invalid on this device.';
      case 18:
        return 'Google Play Services is updating — try again in a moment.';
      default:
        return 'Native scanner unavailable (Play Services code $code).';
    }
  }
}
