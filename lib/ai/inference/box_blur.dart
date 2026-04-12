import 'dart:typed_data';

/// Fast separable box blur over an RGBA8 buffer, implemented with
/// running-sum rows + columns so the cost is **O(pixels)** rather
/// than O(pixels × radius).
///
/// Used by the Phase 9d portrait-smoothing service as a lightweight
/// "skin softener" — a single pass with `radius` derived from the
/// face bounding box gives a decent soft look without shelling out
/// to a bilateral filter (which would need a GPU pass to stay fast).
///
/// The alpha channel is NOT blurred — it stays exactly as the
/// caller passed it. This matches the "replace RGB only" semantic
/// the smoothing pipeline needs (we want a smoothed copy that is
/// later alpha-composited via the face mask, so touching alpha
/// would double-blend edges).
///
/// Kept in pure Dart with no `dart:ui` dependency so the worker-
/// isolate path stays available and unit tests don't need a Flutter
/// binding.
class BoxBlur {
  const BoxBlur._();

  /// Return a new RGBA8 buffer with each RGB channel blurred by a
  /// box kernel of half-width [radius] (so a 3-pixel box has
  /// `radius=1`, a 5-pixel box `radius=2`, etc.). Alpha is copied
  /// through unchanged.
  ///
  /// Throws [ArgumentError] on invalid input.
  static Uint8List blurRgba({
    required Uint8List source,
    required int width,
    required int height,
    required int radius,
  }) {
    if (width <= 0 || height <= 0) {
      throw ArgumentError('width/height must be > 0');
    }
    if (source.length != width * height * 4) {
      throw ArgumentError(
        'source length ${source.length} != ${width * height * 4}',
      );
    }
    if (radius < 0) {
      throw ArgumentError('radius must be >= 0');
    }
    if (radius == 0) return Uint8List.fromList(source);

    // First horizontal pass → into `tmp` (RGB only; alpha copied).
    final tmp = Uint8List(source.length);
    _blurHorizontal(
      src: source,
      dst: tmp,
      width: width,
      height: height,
      radius: radius,
    );
    // Then vertical pass → into `out`, reading from `tmp`.
    final out = Uint8List(source.length);
    _blurVertical(
      src: tmp,
      dst: out,
      width: width,
      height: height,
      radius: radius,
    );
    // Alpha passthrough (both passes left alpha untouched, but we
    // still copy from the ORIGINAL source to guarantee bit-exact
    // alpha even if a future edit breaks that invariant).
    for (int i = 3; i < out.length; i += 4) {
      out[i] = source[i];
    }
    return out;
  }

  /// Single horizontal running-sum pass. Writes into [dst] while
  /// reading from [src]. Alpha is copied unchanged so the output
  /// buffer is self-consistent after one call.
  static void _blurHorizontal({
    required Uint8List src,
    required Uint8List dst,
    required int width,
    required int height,
    required int radius,
  }) {
    for (int y = 0; y < height; y++) {
      final rowStart = y * width * 4;
      int rSum = 0;
      int gSum = 0;
      int bSum = 0;
      int count = 0;
      // Prime the window with the leftmost `radius+1` pixels.
      for (int x = 0; x <= radius && x < width; x++) {
        final idx = rowStart + x * 4;
        rSum += src[idx];
        gSum += src[idx + 1];
        bSum += src[idx + 2];
        count++;
      }
      for (int x = 0; x < width; x++) {
        final outIdx = rowStart + x * 4;
        dst[outIdx] = (rSum / count).round();
        dst[outIdx + 1] = (gSum / count).round();
        dst[outIdx + 2] = (bSum / count).round();
        dst[outIdx + 3] = src[outIdx + 3];

        // Slide the window: subtract the pixel leaving the left
        // edge (if any), add the one entering from the right.
        final leftOut = x - radius;
        final rightIn = x + radius + 1;
        if (leftOut >= 0) {
          final idx = rowStart + leftOut * 4;
          rSum -= src[idx];
          gSum -= src[idx + 1];
          bSum -= src[idx + 2];
          count--;
        }
        if (rightIn < width) {
          final idx = rowStart + rightIn * 4;
          rSum += src[idx];
          gSum += src[idx + 1];
          bSum += src[idx + 2];
          count++;
        }
      }
    }
  }

  /// Vertical running-sum pass. Mirror of [_blurHorizontal] but
  /// stepping by `width * 4` each tick.
  static void _blurVertical({
    required Uint8List src,
    required Uint8List dst,
    required int width,
    required int height,
    required int radius,
  }) {
    final rowStride = width * 4;
    for (int x = 0; x < width; x++) {
      final colStart = x * 4;
      int rSum = 0;
      int gSum = 0;
      int bSum = 0;
      int count = 0;
      for (int y = 0; y <= radius && y < height; y++) {
        final idx = colStart + y * rowStride;
        rSum += src[idx];
        gSum += src[idx + 1];
        bSum += src[idx + 2];
        count++;
      }
      for (int y = 0; y < height; y++) {
        final outIdx = colStart + y * rowStride;
        dst[outIdx] = (rSum / count).round();
        dst[outIdx + 1] = (gSum / count).round();
        dst[outIdx + 2] = (bSum / count).round();
        dst[outIdx + 3] = src[outIdx + 3];

        final topOut = y - radius;
        final bottomIn = y + radius + 1;
        if (topOut >= 0) {
          final idx = colStart + topOut * rowStride;
          rSum -= src[idx];
          gSum -= src[idx + 1];
          bSum -= src[idx + 2];
          count--;
        }
        if (bottomIn < height) {
          final idx = colStart + bottomIn * rowStride;
          rSum += src[idx];
          gSum += src[idx + 1];
          bSum += src[idx + 2];
          count++;
        }
      }
    }
  }
}
