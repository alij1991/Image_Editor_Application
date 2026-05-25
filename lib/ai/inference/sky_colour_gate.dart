/// XVI.100 — Colour-gate the sky mask after the heuristic+SegFormer
/// union so SegFormer's bilinear-upsample bleed doesn't make it into
/// the composite.
///
/// The SegFormer-B0 sky head outputs 128×128 logits that the
/// sky-replace pipeline bilinearly upsamples 16× to source dimensions
/// before unioning into the colour/top-bias heuristic mask. The
/// upsample smears class boundaries across adjacent pixels — red
/// tulips, mountain rock, the brim of a hat — and those pixels land
/// in the mask as "sky" even though their RGB clearly isn't.
///
/// XVI.93a tried to fix this with a `radius=8` guided image filter
/// over the mask using source luminance as a guide. The XVI.99 lab
/// gate (test/ai/lab/op_validation/sky_replace_test.dart) proved
/// that approach is structurally a no-op on real failure scenes:
/// the bleed extends ~30 px into uniform tulip/mountain texture, so
/// the filter's 8-px window sees no luminance gradient to snap to
/// and leaves the bleed intact (Δfpr = +0.0001 on the
/// tulip_bench_portrait fixture).
///
/// This gate takes a different tack: re-ask the colour question
/// for every pixel currently marked as sky. If the source RGB
/// doesn't look like clear blue OR warm sunset OR bright neutral
/// cloud, the pixel was almost certainly added by the SegFormer
/// upsample and is dropped. The gate is deliberately permissive
/// about warm colours (sunset survival) and green colours (the
/// top-bias term of the mask builder already handles foliage). In
/// practice on the tulip_bench_portrait fixture the 24 % fpr win
/// comes from dropping dark neutral mountain-shadow / under-tree
/// pixels in the dilation band, NOT from removing the red / yellow
/// tulip patches themselves (those pass the warmness branch). The
/// `sky_colour_gate_test.dart` unit tests pin this behaviour so
/// future tuning doesn't accidentally tighten the gate so hard
/// that sunset / cloudy scenes start losing real sky.
///
///   XVI.100 lab sweep (lab test results):
///
///   candidate                   coverage    fpr       iou
///   messy (baseline)            0.3838    0.0309    0.9194
///   A: guided r=8 (XVI.93a)     0.3839    0.0310    0.9193
///   D: colour-gate (XVI.100)    0.3763    0.0234    0.9378
library;

import 'dart:typed_data';

/// Drop every pixel from [mask] whose source RGB doesn't look sky-
/// coloured. Operates in place on [mask] and returns the count of
/// pixels removed so the caller can log a `droppedBleedPixels`
/// stat.
///
/// `mask`  must be a `Float32List` of length `width * height`,
///          values in `[0, 1]`.
/// `rgba`  must be a `Uint8List` of length `width * height * 4`,
///          interleaved RGBA bytes.
///
/// A pixel passes the gate when any of:
///   - blueness  = `(B - max(R, G)) / 255  > 0.02`  (clear blue),
///   - warmness  = `(max(R, G) - B) / 255  > 0.10`  (sunset/warm),
///   - `brightness > 0.85` AND `|blueness| < 0.05`
///     AND `|warmness| < 0.05`           (bright neutral cloud).
///
/// Otherwise [mask[i]] is set to 0. The threshold values are
/// regression-tested by `test/ai/lab/op_validation/sky_replace_test.dart`.
int dropNonSkyPixels(
  Float32List mask,
  Uint8List rgba, {
  required int width,
  required int height,
}) {
  if (mask.length != width * height) {
    throw ArgumentError(
      'mask length ${mask.length} != $width * $height',
    );
  }
  if (rgba.length != width * height * 4) {
    throw ArgumentError(
      'rgba length ${rgba.length} != $width * $height * 4',
    );
  }
  int dropped = 0;
  for (var i = 0; i < mask.length; i++) {
    if (mask[i] <= 0) continue;
    final p = i * 4;
    final r = rgba[p];
    final g = rgba[p + 1];
    final b = rgba[p + 2];
    final maxRG = r > g ? r : g;
    final blueness = (b - maxRG) / 255.0;
    final warmness = (maxRG - b) / 255.0;
    final brightness = (r + g + b) / (3.0 * 255.0);
    final isBrightNeutral = brightness > 0.85 &&
        blueness.abs() < 0.05 &&
        warmness.abs() < 0.05;
    final passes = blueness > 0.02 ||
        warmness > 0.10 ||
        isBrightNeutral;
    if (!passes) {
      mask[i] = 0;
      dropped++;
    }
  }
  return dropped;
}
