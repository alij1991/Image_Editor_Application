import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:onnxruntime_v2/onnxruntime_v2.dart' as ort;

import '../../../core/logging/app_logger.dart';
import '../../runtime/ort_runtime.dart';
import '../bg_removal/image_io.dart';
import 'super_res_strategy.dart';

final _log = AppLogger('SuperResX2Service');

/// Phase XVI.53 — Real-ESRGAN-x2plus mobile super-resolution service.
///
/// Doubles input dimensions via a community ONNX export of the
/// Real-ESRGAN-x2plus weights. Smaller (~17 MB FP16) and ~4× faster
/// than the existing x4 service (`SuperResService`); the perceptual
/// lift on phone-sized previews is comparable once the screen
/// downsamples back to native resolution. Drives the default
/// "Enhance 2×" tier in the picker; x4 stays as a power-user toggle
/// with a latency warning.
///
/// ## I/O contract
///
/// **Input:** `[1, 3, inputSize, inputSize]` float32 in `[0, 1]` CHW
/// (Real-ESRGAN convention; ImageNet normalisation is NOT applied —
/// the network was trained on raw `[0, 1]` RGB).
///
/// **Output:** `[1, 3, 2*inputSize, 2*inputSize]` float32 in `[0, 1]`
/// CHW.
///
/// The source is letterboxed (centred with black padding) into a
/// square input, run through the network, and then cropped at 2×
/// scale to recover the original aspect ratio. Same letterbox /
/// crop pattern as the x4 path so a future export-time pipeline
/// can swap strategies without re-deriving the geometry.
class SuperResX2Service implements SuperResStrategy {
  SuperResX2Service({
    required this.session,
    this.inputSize = 256,
  });

  /// Source-decode + network input edge length. 256 px input gives a
  /// 512-px output — comparable to the x4 path's 256 → 1024 budget
  /// at 1/4 the inference cost. Configurable so power users with
  /// more RAM can pass a larger value at the cost of ~quadratic
  /// inference latency.
  final int inputSize;

  /// Output edge length is exactly `2 × inputSize`.
  int get outputSize => inputSize * 2;

  final OrtV2Session session;
  bool _closed = false;

  @override
  SuperResStrategyKind get kind => SuperResStrategyKind.x2;

  @override
  int get scaleFactor => 2;

  @override
  Future<ui.Image> enhanceFromPath(String sourcePath) async {
    if (_closed) {
      _log.w('run rejected — session closed', {'path': sourcePath});
      throw const SuperResException(
        'SuperResX2Service is closed',
        kind: SuperResStrategyKind.x2,
      );
    }
    final total = Stopwatch()..start();
    _log.i('run start', {
      'path': sourcePath,
      'inputs': session.inputNames,
      'outputs': session.outputNames,
      'inputSize': inputSize,
    });

    ort.OrtValue? inputValue;
    List<ort.OrtValue?>? outputs;
    try {
      // 1. Decode source — capped at inputSize so the network sees
      //    the full content of the user's photo (mirrors the x4 path).
      final decoded = await BgRemovalImageIo.decodeFileToRgba(
        sourcePath,
        maxDimension: inputSize,
      );
      final srcW = decoded.width;
      final srcH = decoded.height;
      _log.d('source decoded', {'path': sourcePath, 'w': srcW, 'h': srcH});

      // 2. Build the letterboxed CHW input tensor.
      final preSw = Stopwatch()..start();
      final inputTensor = buildLetterboxedChw(
        rgba: decoded.bytes,
        srcWidth: srcW,
        srcHeight: srcH,
        dstSize: inputSize,
      );
      preSw.stop();
      _log.d('preprocessed', {'ms': preSw.elapsedMilliseconds});

      // 3. Run inference.
      final inputName = pickInputName(session.inputNames);
      if (inputName == null) {
        throw SuperResException(
          'No matching input name on session: ${session.inputNames}',
          kind: SuperResStrategyKind.x2,
        );
      }
      inputValue = ort.OrtValueTensor.createTensorWithDataList(
        inputTensor,
        [1, 3, inputSize, inputSize],
      );

      final inferSw = Stopwatch()..start();
      outputs = await session.runTyped({inputName: inputValue});
      inferSw.stop();
      _log.d('inference', {'ms': inferSw.elapsedMilliseconds});

      if (outputs.isEmpty || outputs.first == null) {
        throw const SuperResException(
          'Real-ESRGAN-x2 returned no output tensor',
          kind: SuperResStrategyKind.x2,
        );
      }

      // 4. Flatten the [1, 3, outputSize, outputSize] tensor.
      final raw = outputs.first!.value;
      final upscaledChw = flattenChw(raw);
      if (upscaledChw == null) {
        throw const SuperResException(
          'Real-ESRGAN-x2 output shape unrecognised — '
          'expected [1, 3, H, W]',
          kind: SuperResStrategyKind.x2,
        );
      }

      // 5. Crop the letterboxed padding at 2× scale to recover the
      //    original aspect ratio.
      final postSw = Stopwatch()..start();
      final scale = inputSize / (srcW > srcH ? srcW : srcH);
      final scaledW = (srcW * scale).round();
      final scaledH = (srcH * scale).round();
      final padX = ((inputSize - scaledW) / 2).round();
      final padY = ((inputSize - scaledH) / 2).round();
      final cropX = padX * 2;
      final cropY = padY * 2;
      final cropW = scaledW * 2;
      final cropH = scaledH * 2;
      final rgba = chwToRgbaCropped(
        chw: upscaledChw,
        chwSize: outputSize,
        cropX: cropX,
        cropY: cropY,
        cropW: cropW,
        cropH: cropH,
      );
      postSw.stop();
      _log.d('postprocessed', {'ms': postSw.elapsedMilliseconds});

      // 6. Upload as a ui.Image at the cropped 2× dimensions.
      final image = await BgRemovalImageIo.encodeRgbaToUiImage(
        rgba: rgba,
        width: cropW,
        height: cropH,
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
    } on SuperResException {
      rethrow;
    } on BgRemovalIoException catch (e) {
      total.stop();
      throw SuperResException(
        e.message,
        kind: SuperResStrategyKind.x2,
        cause: e,
      );
    } catch (e, st) {
      total.stop();
      _log.e('run failed',
          error: e, stackTrace: st, data: {'ms': total.elapsedMilliseconds});
      throw SuperResException(
        e.toString(),
        kind: SuperResStrategyKind.x2,
        cause: e,
      );
    } finally {
      try {
        inputValue?.release();
      } catch (e) {
        _log.w('input release failed', {'error': e.toString()});
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

  /// Match the session's declared input name against the common
  /// Real-ESRGAN ONNX naming conventions ('input' / 'image' /
  /// 'pixel_values'). Falls back to the first declared name when
  /// no candidate matches.
  @visibleForTesting
  static String? pickInputName(List<String> names) {
    const candidates = ['input', 'image', 'pixel_values', 'lr', 'sample'];
    for (final c in candidates) {
      for (final n in names) {
        final lower = n.toLowerCase();
        if (lower == c || lower.endsWith(c)) return n;
      }
    }
    return names.isEmpty ? null : names.first;
  }

  /// Build a letterboxed `[1, 3, dstSize, dstSize]` flat CHW tensor
  /// from a source RGBA buffer. The source is scaled to fit inside
  /// `dstSize × dstSize` while preserving aspect ratio, centred,
  /// with black padding outside.
  ///
  /// Returns the flat Float32List the ONNX session accepts.
  @visibleForTesting
  static Float32List buildLetterboxedChw({
    required Uint8List rgba,
    required int srcWidth,
    required int srcHeight,
    required int dstSize,
  }) {
    final scale = dstSize / (srcWidth > srcHeight ? srcWidth : srcHeight);
    final scaledW = (srcWidth * scale).round();
    final scaledH = (srcHeight * scale).round();
    final padX = ((dstSize - scaledW) / 2).round();
    final padY = ((dstSize - scaledH) / 2).round();

    final yScale = scaledH > 1 ? (srcHeight - 1) / (scaledH - 1) : 0.0;
    final xScale = scaledW > 1 ? (srcWidth - 1) / (scaledW - 1) : 0.0;

    final out = Float32List(3 * dstSize * dstSize);
    final hw = dstSize * dstSize;

    for (var dy = 0; dy < dstSize; dy++) {
      final iy = dy - padY;
      for (var dx = 0; dx < dstSize; dx++) {
        final ix = dx - padX;
        if (iy < 0 || iy >= scaledH || ix < 0 || ix >= scaledW) {
          // Black padding — channels stay at 0 (default Float32List
          // value), only need to skip.
          continue;
        }
        // Bilinear sample from source.
        final sy = iy * yScale;
        final y0 = sy.floor().clamp(0, srcHeight - 1);
        final y1 = (y0 + 1).clamp(0, srcHeight - 1);
        final wy = sy - y0;
        final sx = ix * xScale;
        final x0 = sx.floor().clamp(0, srcWidth - 1);
        final x1 = (x0 + 1).clamp(0, srcWidth - 1);
        final wx = sx - x0;

        final i00 = (y0 * srcWidth + x0) * 4;
        final i01 = (y0 * srcWidth + x1) * 4;
        final i10 = (y1 * srcWidth + x0) * 4;
        final i11 = (y1 * srcWidth + x1) * 4;

        final r = ((rgba[i00] * (1 - wx) + rgba[i01] * wx) * (1 - wy) +
                (rgba[i10] * (1 - wx) + rgba[i11] * wx) * wy) /
            255.0;
        final g =
            ((rgba[i00 + 1] * (1 - wx) + rgba[i01 + 1] * wx) * (1 - wy) +
                    (rgba[i10 + 1] * (1 - wx) +
                            rgba[i11 + 1] * wx) *
                        wy) /
                255.0;
        final b =
            ((rgba[i00 + 2] * (1 - wx) + rgba[i01 + 2] * wx) * (1 - wy) +
                    (rgba[i10 + 2] * (1 - wx) +
                            rgba[i11 + 2] * wx) *
                        wy) /
                255.0;

        final pix = dy * dstSize + dx;
        out[pix] = r;
        out[hw + pix] = g;
        out[2 * hw + pix] = b;
      }
    }
    return out;
  }

  /// Walk a nested `[1, 3, H, W]` (or `[3, H, W]`) tensor into a flat
  /// CHW Float32List.
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
    for (var c = 0; c < 3; c++) {
      final plane = current[c];
      if (plane is! List || plane.length != height) return null;
      for (var y = 0; y < height; y++) {
        final row = plane[y];
        if (row is! List || row.length != width) return null;
        for (var x = 0; x < width; x++) {
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

  /// Convert a flat CHW float buffer to a packed RGBA8 buffer,
  /// cropping a sub-rectangle to recover the source aspect ratio
  /// after letterboxed inference.
  @visibleForTesting
  static Uint8List chwToRgbaCropped({
    required Float32List chw,
    required int chwSize,
    required int cropX,
    required int cropY,
    required int cropW,
    required int cropH,
  }) {
    final hw = chwSize * chwSize;
    final out = Uint8List(cropW * cropH * 4);
    for (var y = 0; y < cropH; y++) {
      final sy = (cropY + y).clamp(0, chwSize - 1);
      for (var x = 0; x < cropW; x++) {
        final sx = (cropX + x).clamp(0, chwSize - 1);
        final src = sy * chwSize + sx;
        final r = chw[src].clamp(0.0, 1.0);
        final g = chw[hw + src].clamp(0.0, 1.0);
        final b = chw[2 * hw + src].clamp(0.0, 1.0);
        final idx = (y * cropW + x) * 4;
        out[idx] = (r * 255).round();
        out[idx + 1] = (g * 255).round();
        out[idx + 2] = (b * 255).round();
        out[idx + 3] = 255;
      }
    }
    return out;
  }
}

/// Stable model id for the bundled Real-ESRGAN-x2 ONNX. Used by the
/// AI bootstrap's `ModelRegistry.resolve()` call.
const String kRealEsrganX2ModelId = 'real_esrgan_x2_fp16';
