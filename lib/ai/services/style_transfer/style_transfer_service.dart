import 'dart:ui' as ui;

import '../../../core/logging/app_logger.dart';

final _log = AppLogger('StyleTransferService');

/// Built-in style catalogue. Each entry will eventually be backed by a
/// pre-baked Magenta style vector (a 1×100 float tensor) so the
/// transfer-half model can run without the larger predict model.
/// For now it just powers the picker UI.
enum StylePreset {
  starryNight('Starry Night', '🌌'),
  candy('Candy', '🍬'),
  woodcut('Woodcut', '🪵'),
  oilPainting('Oil Painting', '🎨'),
  charcoal('Charcoal', '✏️'),
  watercolor('Watercolor', '🖌️');

  const StylePreset(this.label, this.emoji);

  final String label;
  final String emoji;
}

/// Style transfer pipeline (Magenta arbitrary-style, two-network).
///
/// Status: **scaffold**. The bundled `magenta_style_transfer_int8.tflite`
/// model is declared in `assets/models/manifest.json` but the actual
/// binary isn't shipped in the repo and the LiteRT bundled-asset
/// loader still rejects bundled paths. Calling [stylize] today throws
/// [StyleTransferException] with a clear "model unavailable" message
/// the editor surfaces verbatim. The API and UI plumbing are wired so
/// dropping the model file in `assets/models/bundled/` and finishing
/// the loader makes the feature work end-to-end.
///
/// When the model lands, the implementation should:
///   1. Load the transfer model via `LiteRtRuntime.load(resolved)`.
///   2. Pre-bake one 1×100 style vector per [StylePreset] (offline) and
///      ship them as `assets/models/styles/<preset>.bin`.
///   3. In [stylize]: decode source, downscale to 256×256 (Magenta's
///      input resolution), run the transfer model with the chosen
///      style vector, upscale back, return the [ui.Image].
class StyleTransferService {
  StyleTransferService();

  /// Run the full pipeline with [preset] on the image at [sourcePath]
  /// and return the stylised result. Currently throws
  /// [StyleTransferException] until the bundled model + style vectors
  /// land — see class docs.
  Future<ui.Image> stylize({
    required String sourcePath,
    required StylePreset preset,
    double intensity = 1.0,
  }) async {
    _log.i('stylize requested',
        {'preset': preset.name, 'intensity': intensity, 'path': sourcePath});
    throw const StyleTransferException(
      'Style Transfer is not yet available on this build. The Magenta '
      'model needs to be added to assets/models/bundled/. Until then, '
      'try the LUT-backed presets in the bottom strip.',
    );
  }

  Future<void> close() async {
    // No-op until the runtime is wired.
  }
}

/// Typed error for style-transfer failures. Messages are user-facing
/// so the editor can show them verbatim.
class StyleTransferException implements Exception {
  const StyleTransferException(this.message, {this.cause});
  final String message;
  final Object? cause;

  @override
  String toString() {
    if (cause == null) return 'StyleTransferException: $message';
    return 'StyleTransferException: $message (caused by $cause)';
  }
}
