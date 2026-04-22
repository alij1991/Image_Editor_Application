import 'dart:typed_data';

/// Pure-Dart heuristic sky segmentation used by Phase 9g's sky
/// replacement pipeline.
///
/// A proper DeepLabV3 segmenter would give us a learned per-pixel
/// mask, but we can get 90% of the visual quality for the common
/// "sky at top of frame" case by combining four cheap per-pixel
/// signals:
///
///   1. **Blueness** — how much more blue than red/green the pixel
///      is. Computed as `(B - max(R, G)) / 255`, clamped to `[0, 1]`.
///      Captures the classic sky hue without an HSV conversion.
///   2. **Warmness** — how much more red+green than blue the pixel
///      is. Computed as `(max(R, G) - B) / 255`, clamped to `[0, 1]`.
///      Captures golden-hour / sunset skies that blueness alone
///      dismisses. Combined with blueness via `max(...)` so each
///      pixel can qualify as "sky-coloured" via either route; the
///      warmness weight is slightly under blueness so blue skies
///      still win when both signals fire.
///   3. **Brightness** — mean RGB over 255. Sky is almost always
///      well above mid-grey even on overcast days. Dark sky (deep
///      cloud cover) is a known weak spot for the heuristic.
///   4. **Top bias** — a smooth falloff from `1.0` at the top edge
///      of the image to `0.0` at ~60% height. Works because sky
///      rarely wraps around, and most landscape/portrait framings
///      put the sky in the upper half.
///
/// These are combined with fixed weights into a per-pixel score,
/// thresholded, and feathered at the threshold boundary so the
/// composite edge doesn't look cut-out. The output is a
/// `width*height` Float32List in `[0, 1]` — the same shape that
/// `compositeOverlayRgba` accepts, so the sky replacement service
/// plugs into the existing Phase 9d compositing path.
///
/// Kept pure-Dart with no `dart:ui` dependency so it can run inside
/// an isolate worker and be unit-tested without a Flutter binding.
class SkyMaskBuilder {
  const SkyMaskBuilder._();

  /// Build a sky mask from an RGBA8 buffer.
  ///
  /// - [threshold] is the score cutoff below which a pixel is
  ///   treated as "not sky". Defaults to `0.45` — tuned empirically
  ///   to accept typical clear-blue and soft-overcast skies without
  ///   leaking into blue fabric/water. Callers can loosen or
  ///   tighten as needed.
  /// - [featherWidth] is the size of the soft transition zone
  ///   centered on [threshold] in score units. Larger values give a
  ///   softer seam; `0.0` gives a hard binary mask.
  ///
  /// Throws [ArgumentError] on invalid buffer length or
  /// non-positive dimensions.
  static Float32List build({
    required Uint8List source,
    required int width,
    required int height,
    double threshold = 0.45,
    double featherWidth = 0.1,
  }) {
    if (width <= 0 || height <= 0) {
      throw ArgumentError('width and height must be > 0');
    }
    if (source.length != width * height * 4) {
      throw ArgumentError(
        'source length ${source.length} != ${width * height * 4}',
      );
    }
    if (threshold < 0 || threshold > 1) {
      throw ArgumentError('threshold must be in [0, 1]');
    }
    if (featherWidth < 0) {
      throw ArgumentError('featherWidth must be >= 0');
    }

    final mask = Float32List(width * height);
    final halfFeather = featherWidth / 2;
    final low = threshold - halfFeather;
    final high = threshold + halfFeather;

    for (int y = 0; y < height; y++) {
      // Top bias: 1.0 at y=0, 0.0 at y >= 0.6 * height, smooth
      // ramp in between.
      final topEnd = height * 0.6;
      double topBias;
      if (y <= 0) {
        topBias = 1;
      } else if (y >= topEnd) {
        topBias = 0;
      } else {
        final t = 1 - (y / topEnd);
        topBias = t * t * (3 - 2 * t);
      }

      for (int x = 0; x < width; x++) {
        final idx = (y * width + x) * 4;
        final r = source[idx];
        final g = source[idx + 1];
        final b = source[idx + 2];

        final brightness = (r + g + b) / (3 * 255);
        final maxRG = r > g ? r : g;
        final blueness = ((b - maxRG) / 255).clamp(0.0, 1.0);
        final warmness = ((maxRG - b) / 255).clamp(0.0, 1.0);
        // Take the max of the two colour signals so either pathway
        // (clear blue OR warm sunset) can score a sky-coloured pixel;
        // warmness is weighted slightly under blueness so mid-day blue
        // still wins when a pixel happens to carry a little of both.
        final skyColor = blueness > warmness * 0.85
            ? blueness
            : warmness * 0.85;

        final score = skyColor * 0.5 + brightness * 0.3 + topBias * 0.2;

        double alpha;
        if (featherWidth <= 0) {
          alpha = score >= threshold ? 1.0 : 0.0;
        } else if (score <= low) {
          alpha = 0;
        } else if (score >= high) {
          alpha = 1;
        } else {
          final t = (score - low) / featherWidth;
          alpha = t * t * (3 - 2 * t);
        }
        mask[y * width + x] = alpha;
      }
    }
    return mask;
  }
}
