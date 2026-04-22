import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:onnxruntime_v2/onnxruntime_v2.dart' as ort;

import '../../../core/logging/app_logger.dart';
import '../../inference/box_blur.dart';
import '../../inference/image_tensor.dart';
import '../../runtime/ort_runtime.dart';
import '../bg_removal/image_io.dart';

final _log = AppLogger('InpaintService');

/// LaMa inpainting service backed by an ONNX model.
///
/// LaMa takes two inputs:
///   'image': `[1, 3, 512, 512]` float32 in `[0, 1]`
///   'mask':  `[1, 1, 512, 512]` float32 in `{0, 1}` (1 = inpaint)
///
/// Output: `[1, 3, 512, 512]` float32 inpainted image in `[0, 1]`
///
/// ### Region-crop pipeline (Phase XII.A.1)
///
/// Before XII.A.1 this service decoded the source at 512 px so the
/// whole image fit the model's native resolution. That made the
/// resulting layer 512-wide — a ~3.75× upscale on top of a 1920-wide
/// preview, and every pixel (inpainted or not) came out soft.
///
/// The new pipeline keeps the full preview-quality buffer intact and
/// only sends the mask region through LaMa:
///
///   1. Decode source at [BgRemovalImageIo.previewQualityDecodeDimension].
///   2. Compute the mask's bounding box in decoded-image coordinates,
///      pad by [kTilePaddingFraction] to give LaMa context.
///   3. Crop the tile from the decoded buffer.
///   4. Resize the tile to 512×512, run LaMa.
///   5. Resize the 512-output back to tile dimensions.
///   6. Feather-blend the inpainted tile back into the decoded buffer
///      using the user's mask as the blend alpha. Pixels outside the
///      stroke stay at full preview resolution — no upscale artefacts.
///
/// The output `ui.Image` matches the decoded source dimensions, so
/// the layer renderer downsamples slightly onto the preview (clean)
/// instead of upsampling (blurred).
///
/// Ownership of the [OrtV2Session] transfers to this service — [close]
/// releases it.
class InpaintService {
  InpaintService({required this.session});

  /// LaMa's native input/output size.
  static const int inputSize = 512;

  /// Padding added to the mask bbox (as a fraction of bbox size) so
  /// LaMa has surrounding context to synthesise from. Raised to
  /// `0.50` in Phase XIII.8 after observing that large user strokes
  /// produced near-white fills — the mask was occupying >60 % of the
  /// tile pixels, giving LaMa too little context to match texture.
  /// With 50 % padding a 400 × 400 stroke becomes a 800 × 800-ish
  /// tile and the mask drops to ~25 % of the tile area (inside
  /// LaMa's training-distribution sweet spot).
  static const double kTilePaddingFraction = 0.50;

  /// Width of the feathered seam (in decoded-image pixels) between
  /// the inpainted tile and the untouched surroundings. A hard
  /// boundary would show as a visible edge when LaMa's output
  /// doesn't perfectly match the surrounding gradient.
  static const double kSeamFeatherPixels = 8.0;

  final OrtV2Session session;
  bool _closed = false;

  /// Inpaint the image at [sourcePath] using the given [maskRgba].
  ///
  /// [maskRgba] is an RGBA buffer of size [maskWidth] × [maskHeight]
  /// where white (R ≥ 128) pixels mark the region to inpaint.
  ///
  /// Returns a `ui.Image` at preview-quality resolution with only the
  /// mask region replaced by the inpainted result.
  Future<ui.Image> inpaintFromPath(
    String sourcePath, {
    required Uint8List maskRgba,
    required int maskWidth,
    required int maskHeight,
  }) async {
    if (_closed) {
      _log.w('run rejected — session closed', {'path': sourcePath});
      throw const InpaintException('InpaintService is closed');
    }
    final total = Stopwatch()..start();
    _log.i('run start', {
      'path': sourcePath,
      'maskW': maskWidth,
      'maskH': maskHeight,
      'inputs': session.inputNames,
      'outputs': session.outputNames,
    });
    ort.OrtValue? imageInput;
    ort.OrtValue? maskInput;
    List<ort.OrtValue?>? outputs;
    try {
      // 1. Decode source at preview-quality. The decoded buffer is the
      //    canvas we composite back into, so everything outside the
      //    mask stays at full decoded resolution.
      final decoded = await BgRemovalImageIo.decodeFileToRgba(
        sourcePath,
        maxDimension: BgRemovalImageIo.previewQualityDecodeDimension,
      );
      _log.d('source decoded', {
        'path': sourcePath,
        'w': decoded.width,
        'h': decoded.height,
      });

      // 2. Find the mask's bounding box in decoded-image coordinates
      //    and pad for context.
      final bbox = _computeMaskBboxInTarget(
        maskRgba: maskRgba,
        maskWidth: maskWidth,
        maskHeight: maskHeight,
        targetWidth: decoded.width,
        targetHeight: decoded.height,
        paddingFraction: kTilePaddingFraction,
      );
      if (bbox == null) {
        throw const InpaintException(
          'Nothing was painted — paint the area you want to remove '
          'first, then tap done.',
        );
      }
      final maskRatio = _estimateMaskRatioInBbox(
        maskRgba: maskRgba,
        maskWidth: maskWidth,
        maskHeight: maskHeight,
        sourceWidth: decoded.width,
        sourceHeight: decoded.height,
        bbox: bbox,
      );
      _log.d('tile bbox', {
        'x': bbox.x,
        'y': bbox.y,
        'w': bbox.width,
        'h': bbox.height,
        'maskRatio': maskRatio.toStringAsFixed(3),
      });
      if (maskRatio > 0.65) {
        _log.w(
          'mask fills >65% of padded tile — LaMa may produce weak '
          'fill (too little surrounding context); consider smaller '
          'strokes or the padding guard may need to grow',
          {'maskRatio': maskRatio.toStringAsFixed(3)},
        );
      }

      // 3. Crop the tile RGBA + build the 512-tensor.
      final preSw = Stopwatch()..start();
      final tileBytes = _cropRgba(
        source: decoded.bytes,
        srcWidth: decoded.width,
        srcHeight: decoded.height,
        bbox: bbox,
      );
      final imageTensor = ImageTensor.fromRgba(
        rgba: tileBytes,
        srcWidth: bbox.width,
        srcHeight: bbox.height,
        dstWidth: inputSize,
        dstHeight: inputSize,
      );

      // 4. Build the mask tensor from the mask-region inside the bbox.
      final maskTensor = _buildTileMaskTensor(
        maskRgba: maskRgba,
        maskWidth: maskWidth,
        maskHeight: maskHeight,
        sourceWidth: decoded.width,
        sourceHeight: decoded.height,
        bbox: bbox,
        dstSize: inputSize,
      );
      preSw.stop();
      _log.d('preprocessed', {'ms': preSw.elapsedMilliseconds});

      // 5. Wrap tensors as OrtValues.
      imageInput = ort.OrtValueTensor.createTensorWithDataList(
        imageTensor.data,
        imageTensor.shape,
      );
      maskInput = ort.OrtValueTensor.createTensorWithDataList(
        maskTensor,
        [1, 1, inputSize, inputSize],
      );

      // 6. Map input names. LaMa typically uses 'image' and 'mask' but
      //    we match by substring to tolerate variants.
      final inputMap = _mapInputs(
        imageValue: imageInput,
        maskValue: maskInput,
      );

      // 7. Run inference.
      final inferSw = Stopwatch()..start();
      outputs = await session.runTyped(inputMap);
      inferSw.stop();
      _log.d('inference', {'ms': inferSw.elapsedMilliseconds});

      if (outputs.isEmpty || outputs.first == null) {
        throw const InpaintException('LaMa returned no output tensor');
      }

      // 8. Extract the float output [1, 3, 512, 512].
      final raw = outputs.first!.value;
      final inpaintedChw = _flattenChw(raw);
      if (inpaintedChw == null) {
        throw const InpaintException('LaMa output shape unrecognized');
      }

      // 8a. Normalise LaMa output to [0, 1]. Carve/LaMa-ONNX
      //     (what our bundled model points at) actually outputs in
      //     [0, 255] despite what most LaMa docs imply — the diag
      //     log here confirmed `min≈1.4, max≈255, mean≈115`. Auto-
      //     detecting the range once and scaling in-place keeps the
      //     downstream composite unchanged for any future [0, 1]
      //     variant (e.g. the fp16 export or a sigmoid-wrapped
      //     variant).
      _normaliseTensorToUnit(inpaintedChw);

      // 9. Feather-blend the inpainted tile back into the decoded
      //    buffer. Non-mask pixels are identical to decoded.bytes, so
      //    they never suffer a resample.
      final postSw = Stopwatch()..start();
      final compositedRgba = _compositeInpaintedTile(
        originalRgba: decoded.bytes,
        originalWidth: decoded.width,
        originalHeight: decoded.height,
        inpaintedChw: inpaintedChw,
        inpaintedSize: inputSize,
        bbox: bbox,
        maskRgba: maskRgba,
        maskWidth: maskWidth,
        maskHeight: maskHeight,
        seamFeatherPixels: kSeamFeatherPixels,
      );
      postSw.stop();
      _log.d('postprocessed', {'ms': postSw.elapsedMilliseconds});

      // 10. Upload as a ui.Image at the decoded dimensions.
      final image = await BgRemovalImageIo.encodeRgbaToUiImage(
        rgba: compositedRgba,
        width: decoded.width,
        height: decoded.height,
      );
      total.stop();
      _log.i('run complete', {
        'totalMs': total.elapsedMilliseconds,
        'preMs': preSw.elapsedMilliseconds,
        'inferMs': inferSw.elapsedMilliseconds,
        'postMs': postSw.elapsedMilliseconds,
        'outputW': image.width,
        'outputH': image.height,
        'tileW': bbox.width,
        'tileH': bbox.height,
      });
      return image;
    } on InpaintException {
      rethrow;
    } on BgRemovalIoException catch (e) {
      total.stop();
      _log.w('run IO failure — rewrapping', {
        'message': e.message,
        'ms': total.elapsedMilliseconds,
      });
      throw InpaintException(e.message, cause: e);
    } catch (e, st) {
      total.stop();
      _log.e('run failed',
          error: e, stackTrace: st, data: {'ms': total.elapsedMilliseconds});
      throw InpaintException(e.toString(), cause: e);
    } finally {
      try {
        imageInput?.release();
      } catch (e) {
        _log.w('image input release failed', {'error': e.toString()});
      }
      try {
        maskInput?.release();
      } catch (e) {
        _log.w('mask input release failed', {'error': e.toString()});
      }
      if (outputs != null) {
        for (final o in outputs) {
          try {
            o?.release();
          } catch (e) {
            _log.w('output release failed', {'error': e.toString()});
          }
        }
      }
    }
  }

  // ---------------------------------------------------------------
  // Region-crop helpers
  // ---------------------------------------------------------------

  /// Walk the RGBA mask and compute the axis-aligned bounding box of
  /// painted pixels (R ≥ 128). Returns `null` when no pixels are
  /// painted. The bbox is returned in [targetWidth] × [targetHeight]
  /// coordinates (i.e. the decoded source space, not mask space),
  /// padded by [paddingFraction] on every side and clamped to target
  /// bounds.
  static InpaintTileBbox? _computeMaskBboxInTarget({
    required Uint8List maskRgba,
    required int maskWidth,
    required int maskHeight,
    required int targetWidth,
    required int targetHeight,
    required double paddingFraction,
  }) {
    int minX = maskWidth;
    int minY = maskHeight;
    int maxX = -1;
    int maxY = -1;
    for (int y = 0; y < maskHeight; y++) {
      final rowOffset = y * maskWidth * 4;
      for (int x = 0; x < maskWidth; x++) {
        if (maskRgba[rowOffset + x * 4] >= 128) {
          if (x < minX) minX = x;
          if (x > maxX) maxX = x;
          if (y < minY) minY = y;
          if (y > maxY) maxY = y;
        }
      }
    }
    if (maxX < 0) return null;

    final sx = targetWidth / maskWidth;
    final sy = targetHeight / maskHeight;
    double tMinX = minX * sx;
    double tMinY = minY * sy;
    double tMaxX = (maxX + 1) * sx;
    double tMaxY = (maxY + 1) * sy;

    final tileW = tMaxX - tMinX;
    final tileH = tMaxY - tMinY;
    final padX = tileW * paddingFraction;
    final padY = tileH * paddingFraction;
    tMinX = math.max(0.0, tMinX - padX);
    tMinY = math.max(0.0, tMinY - padY);
    tMaxX = math.min(targetWidth.toDouble(), tMaxX + padX);
    tMaxY = math.min(targetHeight.toDouble(), tMaxY + padY);

    // Phase XIII.4: expand the shorter axis to match the longer so
    // the tile we feed LaMa is square. LaMa's 512×512 input resamples
    // any non-square input along both axes, and a thin stroke (e.g.
    // 300×20) would be stretched ~15× vertically — the synthesised
    // fill looks warped and duplicates horizontal features. A square
    // crop keeps the fill aspect-proportional, and when the expansion
    // hits an image edge we accept the residual distortion rather
    // than cropping off context LaMa needs.
    final curW = tMaxX - tMinX;
    final curH = tMaxY - tMinY;
    if (curW > curH) {
      final grow = (curW - curH) / 2.0;
      tMinY = math.max(0.0, tMinY - grow);
      tMaxY = math.min(targetHeight.toDouble(), tMaxY + grow);
    } else if (curH > curW) {
      final grow = (curH - curW) / 2.0;
      tMinX = math.max(0.0, tMinX - grow);
      tMaxX = math.min(targetWidth.toDouble(), tMaxX + grow);
    }

    final x0 = tMinX.floor();
    final y0 = tMinY.floor();
    final x1 = tMaxX.ceil();
    final y1 = tMaxY.ceil();
    final w = math.max(1, x1 - x0);
    final h = math.max(1, y1 - y0);
    return InpaintTileBbox(x: x0, y: y0, width: w, height: h);
  }

  /// Scale the LaMa output tensor in place so every value is in the
  /// `[0, 1]` range the downstream compositor expects.
  ///
  /// Subsamples the tensor to measure the peak magnitude, then:
  ///   - peak ≤ 2.0 → already in `[0, 1]` (or close to it). No-op.
  ///   - peak > 2.0 → assume `[0, 255]` uint8-scale (Carve's export).
  ///     Divide every element by 255. Elements that were legitimately
  ///     negative (rare — the model should clamp) stay negative and
  ///     get clipped by the composite's `clamp(0, 1)`.
  ///
  /// Done in-place so we don't allocate a second 800k-float buffer.
  static void _normaliseTensorToUnit(Float32List chw) {
    if (chw.isEmpty) return;
    double lo = chw[0];
    double hi = chw[0];
    double sum = 0;
    const stride = 256; // subsample for the peak probe
    int counted = 0;
    for (int i = 0; i < chw.length; i += stride) {
      final v = chw[i];
      if (v < lo) lo = v;
      if (v > hi) hi = v;
      sum += v;
      counted++;
    }
    final rawMean = sum / counted;
    if (hi <= 2.0) {
      _log.d('inpainted tensor in [0, 1] range (no rescale)', {
        'min': lo.toStringAsFixed(3),
        'max': hi.toStringAsFixed(3),
        'mean': rawMean.toStringAsFixed(3),
      });
      return;
    }
    // Rescale [0, 255] → [0, 1].
    const inv255 = 1.0 / 255.0;
    for (int i = 0; i < chw.length; i++) {
      chw[i] *= inv255;
    }
    _log.d('inpainted tensor rescaled [0, 255] → [0, 1]', {
      'rawMin': lo.toStringAsFixed(3),
      'rawMax': hi.toStringAsFixed(3),
      'rawMean': rawMean.toStringAsFixed(3),
    });
  }

  /// Return the fraction of the tile's pixel area that is marked
  /// "inpaint this" in the user mask. Used by the run-complete log
  /// to catch the "mask fills the whole tile → LaMa hallucinates"
  /// failure mode before the user notices.
  ///
  /// Samples on an 8 × 8 grid so cost is independent of tile size.
  static double _estimateMaskRatioInBbox({
    required Uint8List maskRgba,
    required int maskWidth,
    required int maskHeight,
    required int sourceWidth,
    required int sourceHeight,
    required InpaintTileBbox bbox,
  }) {
    const gridSize = 16;
    final maskScaleX = maskWidth / sourceWidth;
    final maskScaleY = maskHeight / sourceHeight;
    int hits = 0;
    for (int gy = 0; gy < gridSize; gy++) {
      final srcY = bbox.y + (gy + 0.5) * bbox.height / gridSize;
      final my = (srcY * maskScaleY).floor().clamp(0, maskHeight - 1);
      for (int gx = 0; gx < gridSize; gx++) {
        final srcX = bbox.x + (gx + 0.5) * bbox.width / gridSize;
        final mx = (srcX * maskScaleX).floor().clamp(0, maskWidth - 1);
        if (maskRgba[(my * maskWidth + mx) * 4] >= 128) hits++;
      }
    }
    return hits / (gridSize * gridSize);
  }

  /// Copy a rectangular region of [source] into a fresh RGBA buffer.
  static Uint8List _cropRgba({
    required Uint8List source,
    required int srcWidth,
    required int srcHeight,
    required InpaintTileBbox bbox,
  }) {
    final out = Uint8List(bbox.width * bbox.height * 4);
    for (int y = 0; y < bbox.height; y++) {
      final srcY = bbox.y + y;
      final srcRow = srcY * srcWidth + bbox.x;
      final dstRow = y * bbox.width;
      // Copy 4 * bbox.width bytes per row.
      out.setRange(
        dstRow * 4,
        (dstRow + bbox.width) * 4,
        source,
        srcRow * 4,
      );
    }
    return out;
  }

  /// Build a `[1,1,dstSize,dstSize]` mask tensor covering the bbox
  /// region of the mask. The mask's coordinate space is
  /// [maskWidth] × [maskHeight]; the bbox is in
  /// [sourceWidth] × [sourceHeight] (decoded-image) coordinates. The
  /// tensor samples the original mask nearest-neighbour at each of
  /// the 512 tile pixels.
  static Float32List _buildTileMaskTensor({
    required Uint8List maskRgba,
    required int maskWidth,
    required int maskHeight,
    required int sourceWidth,
    required int sourceHeight,
    required InpaintTileBbox bbox,
    required int dstSize,
  }) {
    final out = Float32List(dstSize * dstSize);
    // Map from tile-local coords → mask coords.
    //   maskCoord = sourceCoord * maskDim / sourceDim
    //   sourceCoord = bbox.x + (tileLocal * bbox.width / dstSize)
    final maskScaleX = maskWidth / sourceWidth;
    final maskScaleY = maskHeight / sourceHeight;
    final tileToSrcX = bbox.width / dstSize;
    final tileToSrcY = bbox.height / dstSize;
    for (int y = 0; y < dstSize; y++) {
      final srcY = bbox.y + y * tileToSrcY;
      final my = (srcY * maskScaleY).floor().clamp(0, maskHeight - 1);
      for (int x = 0; x < dstSize; x++) {
        final srcX = bbox.x + x * tileToSrcX;
        final mx = (srcX * maskScaleX).floor().clamp(0, maskWidth - 1);
        final idx = (my * maskWidth + mx) * 4;
        out[y * dstSize + x] = maskRgba[idx] >= 128 ? 1.0 : 0.0;
      }
    }
    return out;
  }

  /// Feather-blend the LaMa output (a 512×512 CHW float tensor covering
  /// the bbox tile) into [originalRgba] at every pixel the user
  /// painted. The blend alpha is taken from a pre-softened mask so
  /// there's no visible 0→1 cliff at the stroke boundary.
  ///
  /// **Seam feather pipeline (Phase XIII.3):**
  ///   1. Rasterise the user mask onto an RGBA8 tile sized to the
  ///      bbox — hard 0/255 values (threshold at R ≥ 128).
  ///   2. Box-blur the tile by [seamFeatherPixels]. `BoxBlur` is the
  ///      same running-sum implementation the portrait-smooth service
  ///      uses; cost is O(pixels × 1), independent of radius.
  ///   3. Sample the blurred R channel directly as the per-pixel
  ///      alpha. Pixels deep inside the stroke stay at 1.0; pixels
  ///      beyond the feather band stay at 0.0; the boundary ramps
  ///      smoothly between.
  ///
  /// The previous per-pixel 8-sample probe gave a hard 0→1 transition
  /// at the mask edge (inside/outside branches with different alpha
  /// rules), producing a visible seam wherever LaMa's synthesised
  /// colour didn't perfectly match the surrounding gradient. The
  /// pre-blurred approach gives a true distance-like feather for
  /// free.
  static Uint8List _compositeInpaintedTile({
    required Uint8List originalRgba,
    required int originalWidth,
    required int originalHeight,
    required Float32List inpaintedChw,
    required int inpaintedSize,
    required InpaintTileBbox bbox,
    required Uint8List maskRgba,
    required int maskWidth,
    required int maskHeight,
    required double seamFeatherPixels,
  }) {
    final out = Uint8List.fromList(originalRgba);
    final hw = inpaintedSize * inpaintedSize;

    final softMask = _buildSoftenedTileMask(
      maskRgba: maskRgba,
      maskWidth: maskWidth,
      maskHeight: maskHeight,
      originalWidth: originalWidth,
      originalHeight: originalHeight,
      bbox: bbox,
      featherPixels: seamFeatherPixels,
    );

    for (int y = 0; y < bbox.height; y++) {
      final gy = bbox.y + y;
      // Map tile-local y → 512 LaMa-output space.
      final tileY = (y / bbox.height) * inpaintedSize;
      final ty0 = tileY.floor().clamp(0, inpaintedSize - 1);
      final ty1 = (ty0 + 1).clamp(0, inpaintedSize - 1);
      final wy = tileY - ty0;
      final rowOffset = y * bbox.width;
      for (int x = 0; x < bbox.width; x++) {
        final alpha = softMask[rowOffset + x];
        if (alpha <= 0.0) continue;
        _blendInpaintedAt(
          out: out,
          originalWidth: originalWidth,
          inpaintedChw: inpaintedChw,
          inpaintedSize: inpaintedSize,
          hw: hw,
          gx: bbox.x + x,
          gy: gy,
          x: x,
          y: y,
          tileWidth: bbox.width,
          tileHeight: bbox.height,
          ty0: ty0,
          ty1: ty1,
          wy: wy,
          alpha: alpha,
        );
      }
    }
    return out;
  }

  /// Rasterise the hard mask at the bbox region and box-blur it so
  /// the returned `width × height` Float32 buffer is 1.0 deep inside
  /// the stroke, 0.0 well outside, and ramps in between.
  static Float32List _buildSoftenedTileMask({
    required Uint8List maskRgba,
    required int maskWidth,
    required int maskHeight,
    required int originalWidth,
    required int originalHeight,
    required InpaintTileBbox bbox,
    required double featherPixels,
  }) {
    final w = bbox.width;
    final h = bbox.height;
    final maskScaleX = maskWidth / originalWidth;
    final maskScaleY = maskHeight / originalHeight;

    // Build a hard RGBA tile the BoxBlur helper accepts. Values go
    // into all three colour channels because BoxBlur skips alpha;
    // we only read the R channel back out.
    final hardTile = Uint8List(w * h * 4);
    for (int ty = 0; ty < h; ty++) {
      final gy = bbox.y + ty;
      final my = (gy * maskScaleY).floor().clamp(0, maskHeight - 1);
      for (int tx = 0; tx < w; tx++) {
        final gx = bbox.x + tx;
        final mx = (gx * maskScaleX).floor().clamp(0, maskWidth - 1);
        final hit = maskRgba[(my * maskWidth + mx) * 4] >= 128;
        final pix = (ty * w + tx) * 4;
        if (hit) {
          hardTile[pix] = 255;
          hardTile[pix + 1] = 255;
          hardTile[pix + 2] = 255;
        }
        hardTile[pix + 3] = 255;
      }
    }

    final radius = featherPixels.round().clamp(0, 32);
    final blurred = radius == 0
        ? hardTile
        : BoxBlur.blurRgba(
            source: hardTile,
            width: w,
            height: h,
            radius: radius,
          );

    final out = Float32List(w * h);
    for (int i = 0; i < w * h; i++) {
      out[i] = blurred[i * 4] / 255.0;
    }
    return out;
  }

  /// Sample LaMa output (bilinear in the 512-tile space) and alpha-
  /// blend into the output buffer at `(gx, gy)` with `alpha`.
  static void _blendInpaintedAt({
    required Uint8List out,
    required int originalWidth,
    required Float32List inpaintedChw,
    required int inpaintedSize,
    required int hw,
    required int gx,
    required int gy,
    required int x,
    required int y,
    required int tileWidth,
    required int tileHeight,
    required int ty0,
    required int ty1,
    required double wy,
    required double alpha,
  }) {
    final tileX = (x / tileWidth) * inpaintedSize;
    final tx0 = tileX.floor().clamp(0, inpaintedSize - 1);
    final tx1 = (tx0 + 1).clamp(0, inpaintedSize - 1);
    final wx = tileX - tx0;

    // Bilinear sample each channel from the CHW tensor.
    final i00 = ty0 * inpaintedSize + tx0;
    final i01 = ty0 * inpaintedSize + tx1;
    final i10 = ty1 * inpaintedSize + tx0;
    final i11 = ty1 * inpaintedSize + tx1;

    double sampleChannel(int planeOffset) {
      final v00 = inpaintedChw[planeOffset + i00];
      final v01 = inpaintedChw[planeOffset + i01];
      final v10 = inpaintedChw[planeOffset + i10];
      final v11 = inpaintedChw[planeOffset + i11];
      return (v00 * (1 - wx) + v01 * wx) * (1 - wy) +
          (v10 * (1 - wx) + v11 * wx) * wy;
    }

    final r = sampleChannel(0).clamp(0.0, 1.0) * 255;
    final g = sampleChannel(hw).clamp(0.0, 1.0) * 255;
    final b = sampleChannel(hw * 2).clamp(0.0, 1.0) * 255;

    final outIdx = (gy * originalWidth + gx) * 4;
    final origR = out[outIdx].toDouble();
    final origG = out[outIdx + 1].toDouble();
    final origB = out[outIdx + 2].toDouble();
    final inv = 1.0 - alpha;
    out[outIdx] = (origR * inv + r * alpha).round().clamp(0, 255);
    out[outIdx + 1] = (origG * inv + g * alpha).round().clamp(0, 255);
    out[outIdx + 2] = (origB * inv + b * alpha).round().clamp(0, 255);
    // Alpha stays as original.
  }


  /// Map session input names to the image and mask OrtValues.
  ///
  /// LaMa typically names inputs 'image' and 'mask', but we check the
  /// actual session metadata to handle model variations.
  Map<String, ort.OrtValue> _mapInputs({
    required ort.OrtValue imageValue,
    required ort.OrtValue maskValue,
  }) {
    final names = session.inputNames;
    if (names.length < 2) {
      throw InpaintException(
        'LaMa model has ${names.length} inputs, expected 2 (image + mask)',
      );
    }
    String imageName = names[0];
    String maskName = names[1];
    for (final name in names) {
      final lower = name.toLowerCase();
      if (lower.contains('image') || lower.contains('input')) {
        imageName = name;
      } else if (lower.contains('mask')) {
        maskName = name;
      }
    }
    _log.d('input mapping', {
      'imageName': imageName,
      'maskName': maskName,
      'allNames': names,
    });
    return {imageName: imageValue, maskName: maskValue};
  }

  /// Walk a nested `[1][3][H][W]` tensor into a flat [Float32List].
  /// Returns null if the shape doesn't match.
  static Float32List? _flattenChw(Object? raw) {
    if (raw is! List || raw.isEmpty) return null;
    List current = raw;
    if (current.first is List &&
        (current.first as List).isNotEmpty &&
        (current.first as List).first is List) {
      current = current.first as List;
    }
    if (current.length != 3) return null;
    final c0 = current[0];
    if (c0 is! List || c0.isEmpty) return null;
    final height = c0.length;
    if (c0.first is! List) return null;
    final width = (c0.first as List).length;
    if (width == 0) return null;

    final out = Float32List(3 * height * width);
    for (int c = 0; c < 3; c++) {
      final plane = current[c];
      if (plane is! List || plane.length != height) return null;
      for (int y = 0; y < height; y++) {
        final row = plane[y];
        if (row is! List || row.length != width) return null;
        for (int x = 0; x < width; x++) {
          final v = row[x];
          if (v is num) {
            out[c * height * width + y * width + x] = v.toDouble();
          } else {
            return null;
          }
        }
      }
    }
    return out;
  }

  /// Release the underlying session.
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _log.i('close');
    await session.close();
  }
}

/// Rectangular region of the decoded source that gets routed through
/// the LaMa tile pipeline.
class InpaintTileBbox {
  const InpaintTileBbox({
    required this.x,
    required this.y,
    required this.width,
    required this.height,
  });

  final int x;
  final int y;
  final int width;
  final int height;
}

/// Typed exception for inpainting failures.
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
