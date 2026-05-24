import 'dart:typed_data';

/// Phase XVI.83 (A2 of XVI.81 preprocessing audit) — edge-aware mask
/// upsampling via the **guided image filter** (He, Sun & Tang, ECCV
/// 2010 — kaiminghe.github.io/eccv10/).
///
/// ## Why this exists
///
/// Every matter / segmentation service in the editor produces a
/// low-resolution alpha mask (RMBG: 1024², MobileSAM decoder: native
/// at ≤1024 long edge, DeepLab / SegFormer for sky: 256–513,
/// MediaPipe selfie multiclass: 256). The mask is then bilinearly
/// upsampled back to the source's full resolution before being blended
/// into the alpha channel of the cutout.
///
/// Bilinear upsampling is content-blind: it interpolates linearly
/// regardless of what's in the source RGB. On hair, fur, lace, and
/// any high-frequency transition the upsampled mask edge "softens
/// across" the underlying texture, producing the well-known halo /
/// fringe artifacts that every prior phase has fought (XVI.49 edge
/// refine, XVI.66c.fix decontam radius, XVI.73 native-resolution
/// decode).
///
/// The guided filter is the canonical fix. Given a small mask `p`
/// and a high-resolution guide image `I` (the source RGB, projected
/// to luminance), it produces a refined mask `q` whose edges SNAP
/// to luminance edges in the guide. The output is locally a linear
/// transform of the guide:
///
///     q[i] = a[i] * I[i] + b[i]
///
/// where `(a, b)` are computed per-window so that `q ≈ p` while
/// staying smooth wherever `I` is smooth. At a luminance step
/// (e.g. hair vs background), `a` spikes — the mask follows the
/// step rather than interpolating across it.
///
/// ## Implementation
///
/// We use the grayscale-guide variant (luminance via Rec. 601 as
/// `Y = 0.299R + 0.587G + 0.114B`). For 1-channel guide + 1-channel
/// input, the per-pixel solve is a scalar division (no 3×3 matrix
/// inverse the color-guide variant needs), and the math reduces to
/// six box filters plus pixel-wise arithmetic.
///
/// Box filters use a Float64 integral image so the inner loop is O(1)
/// per pixel regardless of radius — without this the algorithm would
/// scale as O(N × r²) and be impractical for the 4–8 px radii we want.
///
/// ## Memory budget
///
/// For a 2048² working canvas the algorithm peaks at ~200 MB of
/// transient buffers (4 × `Float32List(2048²)` plus the integral
/// image which is `Float64List(2049²) ≈ 32 MB`). To bound this on
/// 4K+ sources, [GuidedFilter.upsampleMask] downscales the source
/// to `processingMaxDim` (default 2048) before the filter runs,
/// then bilinearly upsamples the refined mask to the source's
/// actual dimensions. The mask is still edge-aware at the cap
/// resolution — going above only buys ~1 px of additional snap
/// fidelity, which costs more than it's worth on phone CPUs.
///
/// ## Tuning
///
/// - **radius**: window radius in pixels at the working resolution.
///   Larger r = smoother result. 4 px is a good default for matte
///   refinement; 8 px for heavier smoothing.
/// - **epsilon**: regularisation in the local linear solve. Smaller
///   epsilon = sharper edges (snap harder to luminance steps);
///   larger epsilon = smoother (more like bilinear). 1e-4 is the
///   canonical default in the paper for normalised [0, 1] inputs.
class GuidedFilter {
  GuidedFilter._();

  /// Working-resolution cap. When the source exceeds this long-edge
  /// dimension, the algorithm downscales internally to keep memory
  /// bounded.
  static const int kDefaultProcessingMaxDim = 2048;

  /// Default window radius — good for typical matte transition bands
  /// after a 4× upscale (1024 → 4096 source). For sky / large-region
  /// masks raise to 8.
  static const int kDefaultRadius = 4;

  /// Default regularisation. Matches the He et al paper for [0, 1]
  /// normalised inputs.
  static const double kDefaultEpsilon = 1e-4;

  /// Refine a low-resolution alpha mask using the full-resolution
  /// source RGB as edge guide. Returns a refined mask of size
  /// `srcWidth × srcHeight`, values in `[0, 1]`.
  ///
  /// Drop-in for the bilinear upsample step in every matting /
  /// segmentation post-process — the typical caller used to do:
  ///
  ///     final upsampled = bilinearUpsample(mask, ...);
  ///     applyAlpha(upsampled, sourceRgba);
  ///
  /// after XVI.83 instead does:
  ///
  ///     final refined = GuidedFilter.upsampleMask(mask: ..., sourceRgba: ...);
  ///     applyAlpha(refined, sourceRgba);
  static Float32List upsampleMask({
    required Float32List smallMask,
    required int smallWidth,
    required int smallHeight,
    required Uint8List sourceRgba,
    required int srcWidth,
    required int srcHeight,
    int radius = kDefaultRadius,
    double epsilon = kDefaultEpsilon,
    int processingMaxDim = kDefaultProcessingMaxDim,
  }) {
    if (smallMask.length != smallWidth * smallHeight) {
      throw ArgumentError(
        'smallMask length ${smallMask.length} != $smallWidth × $smallHeight',
      );
    }
    final expectedRgba = srcWidth * srcHeight * 4;
    if (sourceRgba.length != expectedRgba) {
      throw ArgumentError(
        'sourceRgba length ${sourceRgba.length} != $srcWidth × $srcHeight × 4',
      );
    }
    if (radius < 1) {
      throw ArgumentError('radius must be >= 1');
    }
    if (epsilon <= 0) {
      throw ArgumentError('epsilon must be > 0');
    }

    // 1. Choose working resolution. Cap to processingMaxDim long edge
    //    to bound RAM on 4K+ sources.
    final longEdge = srcWidth > srcHeight ? srcWidth : srcHeight;
    final scale = longEdge > processingMaxDim ? processingMaxDim / longEdge : 1.0;
    final workW = (srcWidth * scale).round().clamp(8, srcWidth);
    final workH = (srcHeight * scale).round().clamp(8, srcHeight);

    // 2. Bilinear-upsample the small mask to working resolution.
    final p = _bilinearResize(
      src: smallMask,
      srcWidth: smallWidth,
      srcHeight: smallHeight,
      dstWidth: workW,
      dstHeight: workH,
    );

    // 3. Build the luminance guide at working resolution. Skip the
    //    full-res allocation by sampling source RGBA bilinearly into
    //    the working canvas.
    final guide = _luminanceFromRgba(
      rgba: sourceRgba,
      srcWidth: srcWidth,
      srcHeight: srcHeight,
      dstWidth: workW,
      dstHeight: workH,
    );

    // 4. Apply guided filter at the working resolution.
    final refined = _guidedFilter(
      guide: guide,
      p: p,
      width: workW,
      height: workH,
      radius: radius,
      epsilon: epsilon,
    );

    // 5. Bilinear-upsample the refined mask back to source dims if
    //    the working canvas was smaller. When workW/workH == src
    //    this is a no-op identity copy.
    if (workW == srcWidth && workH == srcHeight) return refined;
    return _bilinearResize(
      src: refined,
      srcWidth: workW,
      srcHeight: workH,
      dstWidth: srcWidth,
      dstHeight: srcHeight,
    );
  }

  // ─── building blocks ────────────────────────────────────────────────

  /// He et al guided filter (grayscale guide, grayscale input).
  /// Returns `q[i] = a[i] * guide[i] + b[i]` where `(a, b)` are the
  /// per-window linear coefficients.
  static Float32List _guidedFilter({
    required Float32List guide,
    required Float32List p,
    required int width,
    required int height,
    required int radius,
    required double epsilon,
  }) {
    final n = width * height;
    if (guide.length != n || p.length != n) {
      throw ArgumentError('guide / p length mismatch');
    }

    // 4a. Means of guide and p in the window.
    final meanI = _boxMean(guide, width, height, radius);
    final meanP = _boxMean(p, width, height, radius);

    // 4b. Mean of I*p, then covariance.
    final ip = Float32List(n);
    for (var i = 0; i < n; i++) {
      ip[i] = guide[i] * p[i];
    }
    final meanIp = _boxMean(ip, width, height, radius);
    final covIp = Float32List(n);
    for (var i = 0; i < n; i++) {
      covIp[i] = meanIp[i] - meanI[i] * meanP[i];
    }

    // 4c. Mean of I*I, then variance.
    final ii = Float32List(n);
    for (var i = 0; i < n; i++) {
      final v = guide[i];
      ii[i] = v * v;
    }
    final meanII = _boxMean(ii, width, height, radius);
    final varI = Float32List(n);
    for (var i = 0; i < n; i++) {
      varI[i] = meanII[i] - meanI[i] * meanI[i];
    }

    // 4d. a = cov_Ip / (var_I + eps), b = mean_p - a * mean_I.
    final a = Float32List(n);
    final b = Float32List(n);
    for (var i = 0; i < n; i++) {
      a[i] = covIp[i] / (varI[i] + epsilon);
      b[i] = meanP[i] - a[i] * meanI[i];
    }

    // 4e. Box-mean a and b, then q = mean_a * I + mean_b.
    final meanA = _boxMean(a, width, height, radius);
    final meanB = _boxMean(b, width, height, radius);
    final q = Float32List(n);
    for (var i = 0; i < n; i++) {
      var v = meanA[i] * guide[i] + meanB[i];
      if (v < 0) v = 0;
      if (v > 1) v = 1;
      q[i] = v;
    }
    return q;
  }

  /// Box-mean filter via integral image. O(1) per pixel regardless of
  /// radius — without this the algorithm would scale as O(N × r²).
  static Float32List _boxMean(
    Float32List arr,
    int width,
    int height,
    int radius,
  ) {
    final ii = _integralImage(arr, width, height);
    final out = Float32List(width * height);
    final stride = width + 1;
    for (var y = 0; y < height; y++) {
      final y1 = (y - radius).clamp(0, height - 1);
      final y2 = (y + radius).clamp(0, height - 1);
      final rowH = y2 - y1 + 1;
      final iiTopRow = y1 * stride;
      final iiBotRow = (y2 + 1) * stride;
      for (var x = 0; x < width; x++) {
        final x1 = (x - radius).clamp(0, width - 1);
        final x2 = (x + radius).clamp(0, width - 1);
        final count = rowH * (x2 - x1 + 1);
        final sum = ii[iiBotRow + (x2 + 1)] -
            ii[iiTopRow + (x2 + 1)] -
            ii[iiBotRow + x1] +
            ii[iiTopRow + x1];
        out[y * width + x] = sum / count;
      }
    }
    return out;
  }

  /// Cumulative-sum integral image, padded with a zero row + column
  /// on the top + left so box queries can read `(y1-1, x1-1)` safely.
  /// Returns a Float64List of size `(width + 1) × (height + 1)`.
  static Float64List _integralImage(
    Float32List arr,
    int width,
    int height,
  ) {
    final stride = width + 1;
    final ii = Float64List((width + 1) * (height + 1));
    for (var y = 0; y < height; y++) {
      var rowSum = 0.0;
      final iiRow = (y + 1) * stride;
      final iiPrev = y * stride;
      final arrRow = y * width;
      for (var x = 0; x < width; x++) {
        rowSum += arr[arrRow + x];
        ii[iiRow + (x + 1)] = ii[iiPrev + (x + 1)] + rowSum;
      }
    }
    return ii;
  }

  /// Bilinear resample of a 1-channel Float32 buffer.
  static Float32List _bilinearResize({
    required Float32List src,
    required int srcWidth,
    required int srcHeight,
    required int dstWidth,
    required int dstHeight,
  }) {
    if (srcWidth == dstWidth && srcHeight == dstHeight) {
      return Float32List.fromList(src);
    }
    final out = Float32List(dstWidth * dstHeight);
    final yScale = dstHeight > 1 ? (srcHeight - 1) / (dstHeight - 1) : 0.0;
    final xScale = dstWidth > 1 ? (srcWidth - 1) / (dstWidth - 1) : 0.0;
    for (var y = 0; y < dstHeight; y++) {
      final sy = y * yScale;
      final y0 = sy.floor().clamp(0, srcHeight - 1);
      final y1 = (y0 + 1).clamp(0, srcHeight - 1);
      final wy = sy - y0;
      for (var x = 0; x < dstWidth; x++) {
        final sx = x * xScale;
        final x0 = sx.floor().clamp(0, srcWidth - 1);
        final x1 = (x0 + 1).clamp(0, srcWidth - 1);
        final wx = sx - x0;
        final v00 = src[y0 * srcWidth + x0];
        final v01 = src[y0 * srcWidth + x1];
        final v10 = src[y1 * srcWidth + x0];
        final v11 = src[y1 * srcWidth + x1];
        out[y * dstWidth + x] =
            (v00 * (1 - wx) + v01 * wx) * (1 - wy) +
                (v10 * (1 - wx) + v11 * wx) * wy;
      }
    }
    return out;
  }

  /// Sample the source RGBA bilinearly into a `dstWidth × dstHeight`
  /// canvas and return the Rec. 601 luminance per pixel in `[0, 1]`.
  static Float32List _luminanceFromRgba({
    required Uint8List rgba,
    required int srcWidth,
    required int srcHeight,
    required int dstWidth,
    required int dstHeight,
  }) {
    final out = Float32List(dstWidth * dstHeight);
    final yScale = dstHeight > 1 ? (srcHeight - 1) / (dstHeight - 1) : 0.0;
    final xScale = dstWidth > 1 ? (srcWidth - 1) / (dstWidth - 1) : 0.0;
    for (var y = 0; y < dstHeight; y++) {
      final sy = y * yScale;
      final y0 = sy.floor().clamp(0, srcHeight - 1);
      final y1 = (y0 + 1).clamp(0, srcHeight - 1);
      final wy = sy - y0;
      for (var x = 0; x < dstWidth; x++) {
        final sx = x * xScale;
        final x0 = sx.floor().clamp(0, srcWidth - 1);
        final x1 = (x0 + 1).clamp(0, srcWidth - 1);
        final wx = sx - x0;
        final i00 = (y0 * srcWidth + x0) * 4;
        final i01 = (y0 * srcWidth + x1) * 4;
        final i10 = (y1 * srcWidth + x0) * 4;
        final i11 = (y1 * srcWidth + x1) * 4;
        // Bilinear in uint8 then convert to luminance + normalise.
        final r = (rgba[i00] * (1 - wx) + rgba[i01] * wx) * (1 - wy) +
            (rgba[i10] * (1 - wx) + rgba[i11] * wx) * wy;
        final g =
            (rgba[i00 + 1] * (1 - wx) + rgba[i01 + 1] * wx) * (1 - wy) +
                (rgba[i10 + 1] * (1 - wx) + rgba[i11 + 1] * wx) * wy;
        final bl =
            (rgba[i00 + 2] * (1 - wx) + rgba[i01 + 2] * wx) * (1 - wy) +
                (rgba[i10 + 2] * (1 - wx) + rgba[i11 + 2] * wx) * wy;
        // Rec. 601 luminance, /255 to normalise to [0, 1].
        out[y * dstWidth + x] =
            (0.299 * r + 0.587 * g + 0.114 * bl) / 255.0;
      }
    }
    return out;
  }
}
