import 'package:flutter/foundation.dart';

import '../../core/logging/app_logger.dart';

final _log = AppLogger('DelegateSelector');

/// Which acceleration path a TFLite interpreter should use.
enum TfLiteDelegate { gpu, nnapi, coreml, xnnpack, cpu }

extension TfLiteDelegateX on TfLiteDelegate {
  String get label {
    switch (this) {
      case TfLiteDelegate.gpu:
        return 'GPU';
      case TfLiteDelegate.nnapi:
        return 'NNAPI';
      case TfLiteDelegate.coreml:
        return 'CoreML';
      case TfLiteDelegate.xnnpack:
        return 'XNNPACK';
      case TfLiteDelegate.cpu:
        return 'CPU';
    }
  }
}

/// Device capability hints used by the selector to choose a delegate.
/// We keep these loose because Phase 9a doesn't actually probe the
/// device — Phase 9b will call `device_info_plus` to populate this.
class DeviceCapabilities {
  const DeviceCapabilities({
    required this.platform,
    required this.supportsGpuDelegate,
    required this.supportsNnapi,
    required this.supportsCoreMl,
  });

  final TargetPlatform platform;
  final bool supportsGpuDelegate;
  final bool supportsNnapi;
  final bool supportsCoreMl;

  /// Conservative defaults: CPU fallback only. Override in bootstrap
  /// after probing the real device.
  static const DeviceCapabilities conservative = DeviceCapabilities(
    platform: TargetPlatform.android,
    supportsGpuDelegate: false,
    supportsNnapi: false,
    supportsCoreMl: false,
  );
}

/// Picks the best available delegate for a given model, with a
/// deterministic fallback chain. The fallback is important because
/// many TFLite ops are GPU-unsupported — when the interpreter refuses
/// to build with GPU, the caller catches and re-selects using this
/// class's fallback list.
///
/// Chain logic:
///   iOS  → CoreML → GPU → XNNPACK → CPU
///   Android → NNAPI → GPU → XNNPACK → CPU
///   Other → XNNPACK → CPU
class DelegateSelector {
  const DelegateSelector(this.capabilities);

  final DeviceCapabilities capabilities;

  /// Preferred delegate order for this device. Callers try them in
  /// sequence, catching errors, and use the first one that succeeds.
  List<TfLiteDelegate> preferredChain() {
    final platform = capabilities.platform;
    final chain = <TfLiteDelegate>[];

    if (platform == TargetPlatform.iOS) {
      if (capabilities.supportsCoreMl) chain.add(TfLiteDelegate.coreml);
      if (capabilities.supportsGpuDelegate) chain.add(TfLiteDelegate.gpu);
      chain.add(TfLiteDelegate.xnnpack);
      chain.add(TfLiteDelegate.cpu);
    } else if (platform == TargetPlatform.android) {
      if (capabilities.supportsNnapi) chain.add(TfLiteDelegate.nnapi);
      if (capabilities.supportsGpuDelegate) chain.add(TfLiteDelegate.gpu);
      chain.add(TfLiteDelegate.xnnpack);
      chain.add(TfLiteDelegate.cpu);
    } else {
      chain.add(TfLiteDelegate.xnnpack);
      chain.add(TfLiteDelegate.cpu);
    }

    _log.d('preferredChain', {
      'platform': platform.name,
      'chain': [for (final d in chain) d.label],
    });
    return chain;
  }

  /// Return the preferred chain for ONNX Runtime. ORT has a different
  /// set of execution providers: XNNPACK / NNAPI on Android, CoreML
  /// on iOS, CPU everywhere.
  List<TfLiteDelegate> preferredOnnxChain() {
    final platform = capabilities.platform;
    final chain = <TfLiteDelegate>[];
    if (platform == TargetPlatform.iOS) {
      if (capabilities.supportsCoreMl) chain.add(TfLiteDelegate.coreml);
      chain.add(TfLiteDelegate.xnnpack);
      chain.add(TfLiteDelegate.cpu);
    } else if (platform == TargetPlatform.android) {
      if (capabilities.supportsNnapi) chain.add(TfLiteDelegate.nnapi);
      chain.add(TfLiteDelegate.xnnpack);
      chain.add(TfLiteDelegate.cpu);
    } else {
      chain.add(TfLiteDelegate.cpu);
    }
    return chain;
  }
}
