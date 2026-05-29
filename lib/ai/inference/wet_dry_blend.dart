/// XVI.102 — Wet/dry blend between the source RGBA and a processed
/// output RGBA.
///
/// Background: DnCNN (Reduce Noise) and NAFNet (AI Deblur) are
/// trained to remove noise / blur. When run on an ALREADY clean +
/// sharp photo — the common case for portraits taken in good light
/// on a modern phone — the models still output a smoothed image,
/// because the network learned that "clean" input contains residual
/// noise it should remove and "sharp" input contains residual blur
/// it should sharpen. The result on the user's tulip-bench face was
/// a heavy soften.
///
/// The lab pattern from XVI.99/100 doesn't apply directly because
/// the actual ORT/LiteRT inference can't run inside `flutter test` —
/// only the pre/post processing. But the over-smoothing has a clean
/// pure-Dart mitigation: blend the model output with the source so
/// the user-visible result keeps most of the input's high-frequency
/// detail.
///
///   out = src * (1 - strength) + processed * strength
///
/// `strength = 0`  → identity (no model influence)
/// `strength = 1`  → full model output (pre-XVI.102 behaviour)
/// `strength = 0.5`→ 50/50 blend (default for Reduce Noise)
///
/// Implementation detail: alpha is taken from the *source* — model
/// inference doesn't touch alpha, so a different blend rule would
/// drift transparent edges that the source got right. Concrete
/// callers (denoise / sharpen) hand in opaque source + opaque
/// processed buffers; for forward compat with translucent inputs
/// we still copy source.alpha verbatim.
library;

import 'dart:typed_data';

/// Blend [source] and [processed] RGBA buffers, in place into a new
/// `Uint8List`.
///
/// `source` and `processed` must have the same length and be RGBA-
/// interleaved (i.e. length divisible by 4). `strength` is clamped
/// into [0, 1]. Returns a fresh buffer; the inputs are not mutated.
Uint8List blendWetDry({
  required Uint8List source,
  required Uint8List processed,
  required double strength,
}) {
  if (source.length != processed.length) {
    throw ArgumentError(
      'blendWetDry: source.length=${source.length} != '
      'processed.length=${processed.length}',
    );
  }
  if (source.length % 4 != 0) {
    throw ArgumentError(
      'blendWetDry: buffers must be RGBA-aligned, got length '
      '${source.length}',
    );
  }
  final s = strength.clamp(0.0, 1.0).toDouble();
  final inv = 1.0 - s;
  final out = Uint8List(source.length);
  // Fast-path identity blends.
  if (s == 0.0) {
    out.setAll(0, source);
    return out;
  }
  if (s == 1.0) {
    out.setAll(0, processed);
    return out;
  }
  for (var i = 0; i < source.length; i += 4) {
    final r = source[i] * inv + processed[i] * s;
    final g = source[i + 1] * inv + processed[i + 1] * s;
    final b = source[i + 2] * inv + processed[i + 2] * s;
    out[i] = r.round().clamp(0, 255).toInt();
    out[i + 1] = g.round().clamp(0, 255).toInt();
    out[i + 2] = b.round().clamp(0, 255).toInt();
    // Carry alpha from the source — see library doc.
    out[i + 3] = source[i + 3];
  }
  return out;
}

/// Default mix for Reduce Noise (DnCNN). Lower than the deblur
/// default because aggressive smoothing destroys skin texture, eye
/// catchlights, and hair detail — the most visible regression on
/// the user's portrait. 0.4 still removes most of the noise on a
/// genuinely noisy photo (50% of original noise plus 50% of cleaned
/// version) while keeping faces recognisable on clean ones.
const double kDefaultDenoiseStrength = 0.4;

/// Default mix for AI Deblur (NAFNet). Slightly higher than denoise
/// because deblur output on a genuinely blurry input is usually the
/// desired result, and over-smoothing of a clean image only adds a
/// mild softness that's visually less alarming than denoise's
/// "plastic face" failure mode.
const double kDefaultDeblurStrength = 0.55;
