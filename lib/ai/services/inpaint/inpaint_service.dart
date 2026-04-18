import 'dart:typed_data';
import 'dart:ui' as ui;

import '../../../core/logging/app_logger.dart';

final _log = AppLogger('InpaintService');

/// LaMa-based inpainting / object removal.
///
/// Status: **scaffold**. The `lama_inpaint` ONNX model (~208 MB) is
/// declared in `assets/models/manifest.json` as a download-on-demand
/// entry. The OrtRuntime can already load ONNX models from disk; this
/// service just needs the model file pinned (real `sha256` + verified
/// URL) and the inpaint runner wired up. Until then, [inpaint] throws
/// a [InpaintException] with a clear "model unavailable" message that
/// the editor surfaces verbatim.
///
/// When the model lands, the implementation should:
///   1. Resolve `lama_inpaint` via `ModelRegistry.resolve(...)`. Trigger
///      a download via `ModelDownloader.download(...)` if missing.
///   2. Load the ONNX session via `OrtRuntime.load(resolvedModel)`.
///   3. Pre-process: resize source + mask to LaMa's 512×512 input,
///      feed both as 1×3×H×W (image) and 1×1×H×W (mask) tensors.
///   4. Run inference.
///   5. Composite the inpainted region back into the full-res source
///      via the original mask. Return a [ui.Image].
class InpaintService {
  InpaintService();

  /// Erase the masked region of the source image and fill it from
  /// surrounding pixels. [maskPng] is a single-channel PNG (any
  /// resolution; will be resampled) where white = "remove this"
  /// and black = "keep". Currently throws until the model lands.
  Future<ui.Image> inpaint({
    required String sourcePath,
    required Uint8List maskPng,
  }) async {
    _log.i('inpaint requested', {
      'path': sourcePath,
      'maskBytes': maskPng.length,
    });
    throw const InpaintException(
      'Inpaint is not yet available on this build. The LaMa ONNX '
      'model needs to be downloaded — open Settings → Manage AI '
      'models to fetch it once the URL is pinned.',
    );
  }

  Future<void> close() async {
    // No-op until the runtime is wired.
  }
}

/// Typed error for inpaint failures. Messages are user-facing.
class InpaintException implements Exception {
  const InpaintException(this.message, {this.cause});
  final String message;
  final Object? cause;

  @override
  String toString() {
    if (cause == null) return 'InpaintException: $message';
    return 'InpaintException: $message (caused by $cause)';
  }
}
