import 'dart:ui' as ui;

import '../../../core/logging/app_logger.dart';

final _log = AppLogger('SuperResolutionService');

/// Upscale factor presets exposed in the export sheet. Real-ESRGAN x4
/// is the headline path; the bundled ESPCN x3 fallback is wired in a
/// follow-up so a user with no network can still 3× a photo.
enum SuperResolutionFactor {
  x2('2×'),
  x3('3×'),
  x4('4×');

  const SuperResolutionFactor(this.label);
  final String label;
}

/// Real-ESRGAN-backed super-resolution.
///
/// Status: **scaffold**. The `real_esrgan_x4` TFLite model (~17 MB) is
/// declared in `assets/models/manifest.json` as a download-on-demand
/// entry. LiteRT can already load `.tflite` models from disk; this
/// service needs the model file pinned (real URL + sha256) and the
/// upscale runner wired. Until then, [upscale] throws a
/// [SuperResolutionException] with a clear "model unavailable"
/// message.
///
/// Implementation notes for when the model lands:
///   1. Resolve `real_esrgan_x4` via `ModelRegistry.resolve(...)` and
///      trigger download via `ModelDownloader.download(...)` if missing.
///   2. Load the LiteRT session via `LiteRtRuntime.load(resolvedModel)`.
///   3. Tile the source into ~256×256 blocks (Real-ESRGAN handles
///      arbitrary input via tiling) and run each block in the isolate
///      interpreter. Blend overlapping tile edges with a small feather
///      to hide seams.
///   4. Optional: bundle the ESPCN x3 fallback (already in the
///      manifest as `espcn_3x`) so the service has a no-network path
///      at slightly lower quality.
///   5. Cap memory: very large inputs should stream tiles instead of
///      holding the whole upscaled buffer in RAM.
class SuperResolutionService {
  SuperResolutionService();

  /// Upscale the image at [sourcePath] by [factor]. Real-ESRGAN x4 is
  /// the only physical inference path; x2 / x3 are produced by
  /// downsampling the x4 result so all three options share one model.
  /// Currently throws until the model file lands.
  Future<ui.Image> upscale({
    required String sourcePath,
    required SuperResolutionFactor factor,
  }) async {
    _log.i('upscale requested',
        {'path': sourcePath, 'factor': factor.label});
    throw const SuperResolutionException(
      'Super-resolution is not yet available on this build. The '
      'Real-ESRGAN model needs to be downloaded — open Settings → '
      'Manage AI models once the URL is pinned.',
    );
  }

  Future<void> close() async {
    // No-op until the runtime is wired.
  }
}

/// Typed error for super-resolution failures. Messages are user-facing.
class SuperResolutionException implements Exception {
  const SuperResolutionException(this.message, {this.cause});
  final String message;
  final Object? cause;

  @override
  String toString() {
    if (cause == null) return 'SuperResolutionException: $message';
    return 'SuperResolutionException: $message (caused by $cause)';
  }
}
