import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:onnxruntime_v2/onnxruntime_v2.dart' as ort;

import '../../../core/logging/app_logger.dart';
import '../../inference/box_blur.dart';
import '../../inference/image_tensor.dart';
import '../../runtime/ort_runtime.dart';
import '../bg_removal/image_io.dart';
import 'inpaint_service.dart' show InpaintTileBbox;
import 'inpaint_strategy.dart';

final _log = AppLogger('MiganInpaintService');

/// Phase XVI.51 — MI-GAN inpainting service backed by an ONNX model.
///
/// MI-GAN (Sargsyan et al. 2023, ECCV — Picsart) is a mobile-grade
/// inpainting model designed via knowledge distillation +
/// co-modulation. ~30 MB FP32 ONNX, ~50 ms per call at 512×512 on
/// modern phone CPUs, comparable PSNR to LaMa on standard inpainting
/// benchmarks.
///
/// ## I/O contract
///
/// Both LaMa and MI-GAN share the SAME input/output shape, so the
/// pre/post pipeline mirrors `InpaintService`:
///
///   `image` : `[1, 3, 512, 512]` float32 in `[0, 1]` (HWC→CHW)
///   `mask`  : `[1, 1, 512, 512]` float32 in `{0, 1}` (1 = inpaint)
///   output  : `[1, 3, 512, 512]` float32 inpainted image in `[0, 1]`
///
/// Sanster's IOPaint mirror's MI-GAN export (the URL we ship against
/// by default) uses the input names `'image'` and `'mask'` and the
/// output name `'output'`. The service uses suffix-match name
/// resolution so MI-GAN exports from other mirrors (which sometimes
/// rename to `'sample'` / `'input_mask'`) work without code changes.
///
/// ## Region-crop pipeline
///
/// Mirrors `InpaintService` exactly: bbox the painted region, pad
/// for context, crop, run inference at 512×512, feather-blend the
/// result back into the source. Sharing the geometry helpers avoids
/// drift between the two strategies — a bug in either would surface
/// the same way.
///
/// Ownership of the [OrtV2Session] transfers to this service — [close]
/// releases it.
class MiganInpaintService implements InpaintStrategy {
  MiganInpaintService({required this.session});

  /// MI-GAN's native input/output size — same as LaMa, picked so the
  /// region-crop helpers stay shared.
  static const int inputSize = 512;

  /// Padding around the painted-mask bbox, as a fraction of bbox
  /// size, so MI-GAN has surrounding context. Same value as LaMa
  /// (`InpaintService.kTilePaddingFraction = 0.50`) — both networks
  /// benefit from the same context-to-mask ratio.
  static const double kTilePaddingFraction = 0.50;

  /// Width of the feathered seam between the inpainted tile and the
  /// untouched surroundings.
  static const double kSeamFeatherPixels = 8.0;

  final OrtV2Session session;
  bool _closed = false;

  @override
  InpaintStrategyKind get kind => InpaintStrategyKind.migan;

  @override
  Future<ui.Image> inpaintFromPath(
    String sourcePath, {
    required Uint8List maskRgba,
    required int maskWidth,
    required int maskHeight,
  }) async {
    if (_closed) {
      _log.w('run rejected — session closed', {'path': sourcePath});
      throw const InpaintException(
        'MiganInpaintService is closed',
        kind: InpaintStrategyKind.migan,
      );
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
      // 1. Decode source at preview-quality.
      final decoded = await BgRemovalImageIo.decodeFileToRgba(
        sourcePath,
        maxDimension: BgRemovalImageIo.previewQualityDecodeDimension,
      );
      _log.d('source decoded', {
        'path': sourcePath,
        'w': decoded.width,
        'h': decoded.height,
      });

      // 2. Bbox + pad + square the mask region.
      final bbox = computeMaskBboxInTarget(
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
          kind: InpaintStrategyKind.migan,
        );
      }
      _log.d('tile bbox', {
        'x': bbox.x,
        'y': bbox.y,
        'w': bbox.width,
        'h': bbox.height,
      });

      // 3. Crop the tile and build the 512-tensor.
      final preSw = Stopwatch()..start();
      final tileBytes = cropRgba(
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
      final maskTensor = buildTileMaskTensor(
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

      // 4. Wrap as OrtValues.
      imageInput = ort.OrtValueTensor.createTensorWithDataList(
        imageTensor.data,
        imageTensor.shape,
      );
      maskInput = ort.OrtValueTensor.createTensorWithDataList(
        maskTensor,
        [1, 1, inputSize, inputSize],
      );

      // 5. Resolve names and run inference. MI-GAN exports vary:
      //    Sanster's pipeline uses 'image'/'mask'; some community
      //    exports use 'input'/'input_mask'.
      final inputMap = mapInputs(
        sessionInputs: session.inputNames,
        imageValue: imageInput,
        maskValue: maskInput,
      );

      final inferSw = Stopwatch()..start();
      outputs = await session.runTyped(inputMap);
      inferSw.stop();
      _log.d('inference', {'ms': inferSw.elapsedMilliseconds});

      if (outputs.isEmpty || outputs.first == null) {
        throw const InpaintException(
          'MI-GAN returned no output tensor',
          kind: InpaintStrategyKind.migan,
        );
      }

      // 6. Flatten the [1, 3, 512, 512] output.
      final raw = outputs.first!.value;
      final inpaintedChw = flattenChw(raw);
      if (inpaintedChw == null) {
        throw const InpaintException(
          'MI-GAN output shape unrecognised',
          kind: InpaintStrategyKind.migan,
        );
      }
      // 6a. Some MI-GAN exports emit `[-1, 1]` (tanh activation);
      //     others emit `[0, 1]`. Auto-detect like the LaMa service
      //     and rescale once if needed.
      normaliseTensorToUnit(inpaintedChw);

      // 7. Feather-composite into the source buffer.
      final postSw = Stopwatch()..start();
      final compositedRgba = compositeInpaintedTile(
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

      // 8. Upload as ui.Image.
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
      });
      return image;
    } on InpaintException {
      rethrow;
    } on BgRemovalIoException catch (e) {
      total.stop();
      _log.w('run IO failure — rewrapping', {'message': e.message});
      throw InpaintException(
        e.message,
        kind: InpaintStrategyKind.migan,
        cause: e,
      );
    } catch (e, st) {
      total.stop();
      _log.e('run failed',
          error: e, stackTrace: st, data: {'ms': total.elapsedMilliseconds});
      throw InpaintException(
        e.toString(),
        kind: InpaintStrategyKind.migan,
        cause: e,
      );
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

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _log.i('close');
    await session.close();
  }

  // ===================================================================
  // Pure helpers — exposed for tests.
  // ===================================================================

  /// Compute the painted-mask bounding box in target-image coordinates,
  /// padded by [paddingFraction] and squared so MI-GAN sees an
  /// aspect-square tile. Returns null when nothing was painted.
  ///
  /// Same algorithm as the LaMa service's private helper — kept here
  /// (and not lifted into a shared helper) on purpose so each
  /// strategy can tune its own padding / squaring policy if research
  /// later shows MI-GAN benefits from different proportions.
  @visibleForTesting
  static InpaintTileBbox? computeMaskBboxInTarget({
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

    // Square the tile.
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

  /// Crop a rectangular region of [source] into a fresh RGBA buffer.
  @visibleForTesting
  static Uint8List cropRgba({
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
      out.setRange(
        dstRow * 4,
        (dstRow + bbox.width) * 4,
        source,
        srcRow * 4,
      );
    }
    return out;
  }

  /// Build the `[1,1,dstSize,dstSize]` mask tensor covering the bbox.
  @visibleForTesting
  static Float32List buildTileMaskTensor({
    required Uint8List maskRgba,
    required int maskWidth,
    required int maskHeight,
    required int sourceWidth,
    required int sourceHeight,
    required InpaintTileBbox bbox,
    required int dstSize,
  }) {
    final out = Float32List(dstSize * dstSize);
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

  /// Resolve session input names against the (image, mask) ortvalues.
  /// Tolerates the multiple naming conventions MI-GAN exports use:
  ///   - Sanster's IOPaint: 'image' + 'mask'
  ///   - Picsart reference: 'image' + 'mask' (same)
  ///   - Community variants: 'input' + 'input_mask' / 'sample' + 'mask'
  @visibleForTesting
  static Map<String, ort.OrtValue> mapInputs({
    required List<String> sessionInputs,
    required ort.OrtValue imageValue,
    required ort.OrtValue maskValue,
  }) {
    if (sessionInputs.length < 2) {
      throw InpaintException(
        'MI-GAN model has ${sessionInputs.length} inputs, expected 2',
        kind: InpaintStrategyKind.migan,
      );
    }
    String imageName = sessionInputs[0];
    String maskName = sessionInputs[1];
    for (final name in sessionInputs) {
      final lower = name.toLowerCase();
      if (lower == 'mask' || lower.contains('mask')) {
        maskName = name;
      } else if (lower == 'image' ||
          lower == 'input' ||
          lower == 'sample' ||
          lower.contains('image') ||
          lower.contains('input') && !lower.contains('mask')) {
        imageName = name;
      }
    }
    return {imageName: imageValue, maskName: maskValue};
  }

  /// Walk a nested `[1, 3, H, W]` (or `[3, H, W]`) tensor into a
  /// flat CHW Float32List. Mirrors the LaMa service's helper —
  /// duplicated rather than shared so the two services stay
  /// independently maintainable.
  @visibleForTesting
  static Float32List? flattenChw(Object? raw) {
    if (raw is! List || raw.isEmpty) return null;
    List current = raw;
    if (current.first is List &&
        (current.first as List).isNotEmpty &&
        (current.first as List).first is List &&
        ((current.first as List).first as List).first is List) {
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

  /// Auto-detect the network's output range and rescale to `[0, 1]`
  /// in place. Some MI-GAN exports use a tanh activation (`[-1, 1]`),
  /// others sigmoid (`[0, 1]`). A subsampled probe is enough — both
  /// distributions are wide enough that ~1k samples reliably tells
  /// us which we have.
  @visibleForTesting
  static void normaliseTensorToUnit(Float32List chw) {
    if (chw.isEmpty) return;
    double lo = chw[0];
    double hi = chw[0];
    const stride = 256;
    for (int i = 0; i < chw.length; i += stride) {
      final v = chw[i];
      if (v < lo) lo = v;
      if (v > hi) hi = v;
    }
    if (lo >= -0.05 && hi <= 1.05) {
      // Already in [0, 1] (allowing for tiny overshoot).
      return;
    }
    if (lo >= -1.1 && hi <= 1.1) {
      // tanh-style [-1, 1] → [0, 1].
      for (int i = 0; i < chw.length; i++) {
        chw[i] = (chw[i] + 1.0) * 0.5;
      }
      _log.d('rescaled tensor [-1, 1] → [0, 1]', {
        'rawMin': lo.toStringAsFixed(3),
        'rawMax': hi.toStringAsFixed(3),
      });
      return;
    }
    if (hi > 2.0) {
      // [0, 255] uint8-scale (rare for MI-GAN but defensive).
      const inv255 = 1.0 / 255.0;
      for (int i = 0; i < chw.length; i++) {
        chw[i] *= inv255;
      }
      _log.d('rescaled tensor [0, 255] → [0, 1]');
    }
  }

  /// Feather-blend the inpainted tile back into the original buffer.
  @visibleForTesting
  static Uint8List compositeInpaintedTile({
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
      final tileY = (y / bbox.height) * inpaintedSize;
      final ty0 = tileY.floor().clamp(0, inpaintedSize - 1);
      final ty1 = (ty0 + 1).clamp(0, inpaintedSize - 1);
      final wy = tileY - ty0;
      final rowOffset = y * bbox.width;
      for (int x = 0; x < bbox.width; x++) {
        final alpha = softMask[rowOffset + x];
        if (alpha <= 0.0) continue;
        final tileX = (x / bbox.width) * inpaintedSize;
        final tx0 = tileX.floor().clamp(0, inpaintedSize - 1);
        final tx1 = (tx0 + 1).clamp(0, inpaintedSize - 1);
        final wx = tileX - tx0;

        final i00 = ty0 * inpaintedSize + tx0;
        final i01 = ty0 * inpaintedSize + tx1;
        final i10 = ty1 * inpaintedSize + tx0;
        final i11 = ty1 * inpaintedSize + tx1;

        double sample(int planeOffset) {
          final v00 = inpaintedChw[planeOffset + i00];
          final v01 = inpaintedChw[planeOffset + i01];
          final v10 = inpaintedChw[planeOffset + i10];
          final v11 = inpaintedChw[planeOffset + i11];
          return (v00 * (1 - wx) + v01 * wx) * (1 - wy) +
              (v10 * (1 - wx) + v11 * wx) * wy;
        }

        final r = sample(0).clamp(0.0, 1.0) * 255;
        final g = sample(hw).clamp(0.0, 1.0) * 255;
        final b = sample(hw * 2).clamp(0.0, 1.0) * 255;

        final outIdx = (gy * originalWidth + bbox.x + x) * 4;
        final origR = out[outIdx].toDouble();
        final origG = out[outIdx + 1].toDouble();
        final origB = out[outIdx + 2].toDouble();
        final inv = 1.0 - alpha;
        out[outIdx] = (origR * inv + r * alpha).round().clamp(0, 255);
        out[outIdx + 1] = (origG * inv + g * alpha).round().clamp(0, 255);
        out[outIdx + 2] = (origB * inv + b * alpha).round().clamp(0, 255);
      }
    }
    return out;
  }

  /// Same softened-tile-mask helper LaMa uses — duplicated so both
  /// strategies can be edited independently. Cost is one box-blur
  /// over the bbox region.
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
}

/// Stable model id for the bundled MI-GAN pipeline. Used by the AI
/// bootstrap's `ModelRegistry.resolve()` call.
const String kMiganInpaintModelId = 'migan_512_fp32';
