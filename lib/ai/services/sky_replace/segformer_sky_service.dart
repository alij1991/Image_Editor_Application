import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:onnxruntime_v2/onnxruntime_v2.dart' as ort;

import '../../../core/logging/app_logger.dart';
import '../../inference/image_tensor.dart';
import '../../runtime/ort_runtime.dart';

final _log = AppLogger('SegFormerSkyService');

/// Phase XVI.52 — SegFormer-B0 (Xie et al. 2021) ADE20K-trained sky
/// segmenter. Wires alongside the existing DeepLabV3 ADE20K path to
/// give users a "high-quality" sky detection toggle.
///
/// SegFormer-B0 is the smallest variant of the SegFormer family
/// (~3.7M parameters, ~14 MB INT8) and outperforms DeepLabV3-MobileNet
/// on the standard ADE20K mIoU benchmark by ~3 points (37.4% vs 34.1%
/// on the official validation set). The lift is most visible on
/// challenging sky boundaries — soft-edged horizons, foliage-against-
/// sky, water-vs-sky reflections.
///
/// ## I/O contract
///
/// Inputs:  `'pixel_values'` `[1, 3, 512, 512]` float32, ImageNet-
///          normalized (mean=[0.485, 0.456, 0.406],
///          std=[0.229, 0.224, 0.225]).
/// Outputs: `'logits'` `[1, 150, 128, 128]` float32 — per-class
///          logits at 1/4 the input spatial resolution (the MiT
///          encoder's stride). The sky class index follows the
///          SceneParse150 label list — typically 2 (zero-indexed) but
///          configurable via [skyClassIndex] so non-standard exports
///          drop in.
///
/// Returns the per-pixel sky probability after softmax → sigmoid-
/// equivalent mask + bilinear upsample to the requested destination
/// size. The consumer (SkyReplaceService) then unions this with the
/// heuristic mask before painting the replacement.
class SegFormerSkyService {
  SegFormerSkyService({
    required this.session,
    this.skyClassIndex = ade20kSkyClass,
  });

  /// Native input edge length. SegFormer-B0 fine-tuned on ADE20K is
  /// trained at 512×512; non-512 inputs work (the model is fully
  /// convolutional) but quality drops outside the training
  /// distribution.
  static const int inputSize = 512;

  /// SegFormer's output spatial size — 1/4 the input due to the
  /// MiT-B0 encoder's downsample stride.
  static const int outputSize = 128;

  /// SceneParse150 / ADE20K class count (zero-indexed: wall=0,
  /// building=1, sky=2, floor=3, …).
  static const int numClasses = 150;

  /// Default sky-class index for SegFormer-B0 fine-tuned on ADE20K
  /// per the SceneParse150 label list (different from the
  /// 151-class DeepLab variant which uses 3 because that model
  /// reserves index 0 for "unlabeled").
  static const int ade20kSkyClass = 2;

  /// ImageNet preprocessing constants. SegFormer was trained on the
  /// HuggingFace `transformers.image_processing` pipeline.
  static const List<double> imageNetMean = [0.485, 0.456, 0.406];
  static const List<double> imageNetStd = [0.229, 0.224, 0.225];

  /// Per-instance sky class index — defaults to [ade20kSkyClass] but
  /// overridable for ONNX exports that use non-standard label maps.
  final int skyClassIndex;

  final OrtV2Session session;
  bool _closed = false;

  /// Run SegFormer on [sourceRgba] and return the resulting sky mask
  /// at `(dstWidth × dstHeight)` via bilinear upsample. Mask values
  /// are in `[0, 1]` — the consumer can threshold or blend
  /// directly. The `SkyMaskResult` carries the mask + the model's
  /// raw output dimensions for diagnostics.
  Future<SkyMaskResult> runSkyMaskOnRgba({
    required Uint8List sourceRgba,
    required int sourceWidth,
    required int sourceHeight,
    required int dstWidth,
    required int dstHeight,
  }) async {
    if (_closed) {
      throw const SegFormerSkyException('service is closed');
    }
    if (sourceRgba.length != sourceWidth * sourceHeight * 4) {
      throw ArgumentError(
        'sourceRgba length ${sourceRgba.length} != '
        '${sourceWidth * sourceHeight * 4}',
      );
    }
    final total = Stopwatch()..start();
    _log.i('run start', {
      'srcW': sourceWidth,
      'srcH': sourceHeight,
      'dstW': dstWidth,
      'dstH': dstHeight,
      'inputs': session.inputNames,
      'outputs': session.outputNames,
    });

    ort.OrtValue? inputValue;
    List<ort.OrtValue?>? outputs;
    try {
      // 1. Build [1, 3, 512, 512] ImageNet-normalized input tensor.
      final preSw = Stopwatch()..start();
      final tensor = ImageTensor.fromRgba(
        rgba: sourceRgba,
        srcWidth: sourceWidth,
        srcHeight: sourceHeight,
        dstWidth: inputSize,
        dstHeight: inputSize,
        mean: imageNetMean,
        std: imageNetStd,
      );
      preSw.stop();

      // 2. Wrap input + run inference. SegFormer ONNX exports
      //    typically use 'pixel_values' as the input name (the
      //    HuggingFace transformers convention); fall back to
      //    'input' / 'image' for community variants.
      final inputName = pickInputName(session.inputNames);
      if (inputName == null) {
        throw SegFormerSkyException(
          'No matching input name on session: ${session.inputNames}',
        );
      }
      inputValue = ort.OrtValueTensor.createTensorWithDataList(
        tensor.data,
        tensor.shape,
      );

      final inferSw = Stopwatch()..start();
      outputs = await session.runTyped({inputName: inputValue});
      inferSw.stop();
      _log.d('inference', {'ms': inferSw.elapsedMilliseconds});

      if (outputs.isEmpty || outputs.first == null) {
        throw const SegFormerSkyException(
          'SegFormer returned no output tensor',
        );
      }

      // 3. Flatten the [1, 150, 128, 128] logits tensor.
      final raw = outputs.first!.value;
      final logits = flattenLogits(raw);
      if (logits == null) {
        throw const SegFormerSkyException(
          'SegFormer logits shape unrecognised — expected [1, C, H, W]',
        );
      }

      // 4. Compute the sky-mask at output resolution via softmax →
      //    pick the sky class. For a [C, H, W] tensor the softmax is
      //    per-pixel across the C axis.
      final postSw = Stopwatch()..start();
      final smallMask = softmaxSkyClass(
        logits: logits.data,
        height: logits.height,
        width: logits.width,
        numClasses: logits.numClasses,
        skyClassIndex: skyClassIndex,
      );

      // 5. Bilinear-resize the small mask to the requested target.
      final mask = bilinearResize(
        src: smallMask,
        srcWidth: logits.width,
        srcHeight: logits.height,
        dstWidth: dstWidth,
        dstHeight: dstHeight,
      );
      postSw.stop();

      total.stop();
      _log.i('run complete', {
        'totalMs': total.elapsedMilliseconds,
        'preMs': preSw.elapsedMilliseconds,
        'inferMs': inferSw.elapsedMilliseconds,
        'postMs': postSw.elapsedMilliseconds,
        'logitW': logits.width,
        'logitH': logits.height,
        'logitC': logits.numClasses,
      });
      return SkyMaskResult(
        mask: mask,
        width: dstWidth,
        height: dstHeight,
        rawWidth: logits.width,
        rawHeight: logits.height,
      );
    } on SegFormerSkyException {
      rethrow;
    } catch (e, st) {
      total.stop();
      _log.e('run failed',
          error: e, stackTrace: st, data: {'ms': total.elapsedMilliseconds});
      throw SegFormerSkyException(e.toString(), cause: e);
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
  /// SegFormer / HuggingFace naming conventions. Falls back to the
  /// first declared name when no candidate matches.
  @visibleForTesting
  static String? pickInputName(List<String> names) {
    const candidates = ['pixel_values', 'input', 'image', 'sample'];
    for (final c in candidates) {
      for (final n in names) {
        final lower = n.toLowerCase();
        if (lower == c || lower.endsWith(c)) return n;
      }
    }
    return names.isEmpty ? null : names.first;
  }

  /// Walk a nested SegFormer logits tensor `[1, C, H, W]` (or
  /// `[C, H, W]`) into a flat CHW Float32List with metadata. Returns
  /// null when the shape doesn't match.
  @visibleForTesting
  static SegFormerLogits? flattenLogits(Object? raw) {
    if (raw is! List || raw.isEmpty) return null;
    List current = raw;
    // Drop the leading batch dim if present.
    if (current.first is List &&
        (current.first as List).isNotEmpty &&
        (current.first as List).first is List &&
        ((current.first as List).first as List).first is List) {
      current = current.first as List;
    }
    if (current.isEmpty || current.first is! List) return null;
    final c = current.length;
    final c0 = current[0];
    if (c0 is! List || c0.isEmpty) return null;
    final h = c0.length;
    if (c0.first is! List) return null;
    final w = (c0.first as List).length;
    if (w == 0) return null;

    final out = Float32List(c * h * w);
    for (int ci = 0; ci < c; ci++) {
      final plane = current[ci];
      if (plane is! List || plane.length != h) return null;
      for (int y = 0; y < h; y++) {
        final row = plane[y];
        if (row is! List || row.length != w) return null;
        for (int x = 0; x < w; x++) {
          final v = row[x];
          if (v is num) {
            out[ci * h * w + y * w + x] = v.toDouble();
          } else {
            return null;
          }
        }
      }
    }
    return SegFormerLogits(
      data: out,
      numClasses: c,
      height: h,
      width: w,
    );
  }

  /// Softmax across the class axis of a CHW logits tensor and return
  /// the per-pixel probability that the pixel belongs to
  /// [skyClassIndex]. Result is row-major `width × height`.
  ///
  /// Numerically stable — subtracts the per-pixel max from every
  /// logit before exp() so the sum stays in the float32 range even
  /// at very large logit magnitudes.
  @visibleForTesting
  static Float32List softmaxSkyClass({
    required Float32List logits,
    required int height,
    required int width,
    required int numClasses,
    required int skyClassIndex,
  }) {
    if (skyClassIndex < 0 || skyClassIndex >= numClasses) {
      throw ArgumentError(
        'skyClassIndex $skyClassIndex out of range [0, $numClasses)',
      );
    }
    if (logits.length != numClasses * height * width) {
      throw ArgumentError(
        'logits length ${logits.length} != '
        '${numClasses * height * width} (CHW expected)',
      );
    }
    final out = Float32List(width * height);
    final hw = height * width;
    for (int p = 0; p < hw; p++) {
      // Per-pixel max for numerical stability.
      double maxLogit = logits[p]; // class 0 logit at this pixel
      for (int c = 1; c < numClasses; c++) {
        final v = logits[c * hw + p];
        if (v > maxLogit) maxLogit = v;
      }
      double sumExp = 0;
      for (int c = 0; c < numClasses; c++) {
        sumExp += _exp(logits[c * hw + p] - maxLogit);
      }
      if (sumExp <= 0) {
        out[p] = 0;
        continue;
      }
      final skyExp = _exp(logits[skyClassIndex * hw + p] - maxLogit);
      out[p] = (skyExp / sumExp).clamp(0.0, 1.0).toDouble();
    }
    return out;
  }

  /// Bilinearly resample a single-channel mask from
  /// `srcWidth × srcHeight` to `dstWidth × dstHeight`. Same algorithm
  /// as `SegmentationResult.bilinearResize` — duplicated here so
  /// SegFormer doesn't pull in the LiteRT-only segmentation_service
  /// import for one helper.
  @visibleForTesting
  static Float32List bilinearResize({
    required Float32List src,
    required int srcWidth,
    required int srcHeight,
    required int dstWidth,
    required int dstHeight,
  }) {
    final out = Float32List(dstWidth * dstHeight);
    final xScale = srcWidth / dstWidth;
    final yScale = srcHeight / dstHeight;
    for (int dy = 0; dy < dstHeight; dy++) {
      final sy = (dy + 0.5) * yScale - 0.5;
      final y0 = sy.floor().clamp(0, srcHeight - 1);
      final y1 = (y0 + 1).clamp(0, srcHeight - 1);
      final wy = (sy - y0).clamp(0.0, 1.0);
      for (int dx = 0; dx < dstWidth; dx++) {
        final sx = (dx + 0.5) * xScale - 0.5;
        final x0 = sx.floor().clamp(0, srcWidth - 1);
        final x1 = (x0 + 1).clamp(0, srcWidth - 1);
        final wx = (sx - x0).clamp(0.0, 1.0);
        final v00 = src[y0 * srcWidth + x0];
        final v01 = src[y0 * srcWidth + x1];
        final v10 = src[y1 * srcWidth + x0];
        final v11 = src[y1 * srcWidth + x1];
        out[dy * dstWidth + dx] =
            (v00 * (1 - wx) + v01 * wx) * (1 - wy) +
                (v10 * (1 - wx) + v11 * wx) * wy;
      }
    }
    return out;
  }

  /// Numerically-stable `exp(x)` with a saturation guard. Extremely
  /// negative logits would produce subnormal floats that the
  /// softmax denominator can drop; clamping the floor keeps the
  /// denom well-conditioned.
  static double _exp(double x) {
    if (x < -50) return 0;
    return math.exp(x);
  }
}

/// Carries the SegFormer logits tensor + its dimensions. Returned by
/// [SegFormerSkyService.flattenLogits].
class SegFormerLogits {
  const SegFormerLogits({
    required this.data,
    required this.numClasses,
    required this.height,
    required this.width,
  });

  final Float32List data;
  final int numClasses;
  final int height;
  final int width;
}

/// Result of a SegFormer sky-segmentation run. The mask is the
/// caller-requested resolution; rawWidth/rawHeight expose the model's
/// native output for diagnostics.
class SkyMaskResult {
  const SkyMaskResult({
    required this.mask,
    required this.width,
    required this.height,
    required this.rawWidth,
    required this.rawHeight,
  });

  final Float32List mask;
  final int width;
  final int height;
  final int rawWidth;
  final int rawHeight;
}

class SegFormerSkyException implements Exception {
  const SegFormerSkyException(this.message, {this.cause});
  final String message;
  final Object? cause;

  @override
  String toString() {
    if (cause == null) return 'SegFormerSkyException: $message';
    return 'SegFormerSkyException: $message (caused by $cause)';
  }
}

/// Stable model id for the SegFormer-B0 sky segmenter. Used by the
/// AI bootstrap's `ModelRegistry.resolve()` call.
const String kSegFormerB0SkyModelId = 'segformer_b0_ade20k_512_int8';
