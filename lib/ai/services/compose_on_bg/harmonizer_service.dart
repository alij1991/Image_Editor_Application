import 'dart:typed_data';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:onnxruntime_v2/onnxruntime_v2.dart' as ort;

import '../../../core/logging/app_logger.dart';
import '../../inference/image_tensor.dart';
import '../../runtime/ort_runtime.dart';

final _log = AppLogger('HarmonizerService');

/// Phase XVI.54 — Harmonizer (Ke et al. 2022, ECCV) compose-on-bg
/// harmonisation tier.
///
/// Harmonizer is a small (~2M params, ~8 MB ONNX) white-box filter
/// regressor: it predicts a vector of 8 photo-editing parameters
/// (brightness / contrast / saturation / temperature / tint /
/// sharpness / highlights / shadows) that, when applied to the
/// subject foreground inside the unmasked composite, harmonise it
/// against the background's lighting and colour palette.
///
/// The "white-box" framing is the critical bit: instead of
/// outputting a recoloured raster (black box) the network outputs
/// the SAME knobs the existing shader chain already applies. We
/// can render the harmonised composite via the existing shader
/// pipeline at full resolution, with no model-resolution-dependent
/// quality loss.
///
/// ## I/O contract
///
/// **Inputs (float32, ImageNet-normalised):**
/// - `composite`: `[1, 3, 256, 256]` — pre-recolour composite of
///   subject pasted onto bg.
/// - `mask`: `[1, 1, 256, 256]` — foreground mask (1.0 = subject).
///
/// **Output:** `[1, 8]` float32 filter arguments per the order:
///   `[brightness, contrast, saturation, temperature, tint,
///    sharpness, highlights, shadows]`
/// Each argument is a slider-space value that maps directly to the
/// corresponding `EditOpType` shader parameter (the consumer
/// applies them via `EditPipeline` ops, NOT a re-render — keeps
/// quality at full preview resolution).
///
/// ## Pipeline integration
///
/// `ComposeOnBackgroundService` runs Harmonizer at step 4a (before
/// the existing Reinhard LAB transfer at step 4). Reinhard becomes
/// a residual transfer: when Harmonizer's output already matches
/// the bg palette closely Reinhard's contribution shrinks toward
/// zero. When the model isn't available the service falls back to
/// pre-XVI.54 behaviour (Reinhard alone) — silent fallback per
/// project convention.
class HarmonizerService {
  HarmonizerService({required this.session});

  /// Network's fixed input resolution. Harmonizer was trained at
  /// 256×256 — non-square / different sizes work (it's fully
  /// convolutional except for the final regressor head) but
  /// quality drops outside the training distribution.
  static const int inputSize = 256;

  /// Number of filter arguments the regressor head emits.
  static const int numFilterArgs = 8;

  /// ImageNet preprocessing constants. Harmonizer used the standard
  /// HuggingFace `transformers.image_processing` pipeline during
  /// training; the ONNX export expects the same.
  static const List<double> imageNetMean = [0.485, 0.456, 0.406];
  static const List<double> imageNetStd = [0.229, 0.224, 0.225];

  final OrtV2Session session;
  bool _closed = false;

  /// Run Harmonizer on a composite image + foreground mask. Returns
  /// the predicted filter arguments. The caller (compose service)
  /// applies them to the subject region via the existing shader
  /// chain, not re-rendering through this service.
  Future<HarmonizerArgs> predictFilterArgs({
    required Uint8List compositeRgba,
    required int compositeWidth,
    required int compositeHeight,
    required Float32List foregroundMask,
    required int maskWidth,
    required int maskHeight,
  }) async {
    if (_closed) {
      throw const HarmonizerException('HarmonizerService is closed');
    }
    if (compositeRgba.length !=
        compositeWidth * compositeHeight * 4) {
      throw ArgumentError(
        'compositeRgba length ${compositeRgba.length} != '
        '${compositeWidth * compositeHeight * 4}',
      );
    }
    if (foregroundMask.length != maskWidth * maskHeight) {
      throw ArgumentError(
        'foregroundMask length ${foregroundMask.length} != '
        '${maskWidth * maskHeight}',
      );
    }
    final total = Stopwatch()..start();
    _log.i('run start', {
      'compositeW': compositeWidth,
      'compositeH': compositeHeight,
      'inputs': session.inputNames,
      'outputs': session.outputNames,
    });

    ort.OrtValue? compositeInput;
    ort.OrtValue? maskInput;
    List<ort.OrtValue?>? outputs;
    try {
      // 1. Build [1, 3, 256, 256] ImageNet-normalised composite tensor.
      final preSw = Stopwatch()..start();
      final compositeTensor = ImageTensor.fromRgba(
        rgba: compositeRgba,
        srcWidth: compositeWidth,
        srcHeight: compositeHeight,
        dstWidth: inputSize,
        dstHeight: inputSize,
        mean: imageNetMean,
        std: imageNetStd,
      );

      // 2. Build [1, 1, 256, 256] mask tensor (bilinearly resized).
      final maskTensor = bilinearResizeMask(
        src: foregroundMask,
        srcWidth: maskWidth,
        srcHeight: maskHeight,
        dstWidth: inputSize,
        dstHeight: inputSize,
      );
      preSw.stop();
      _log.d('preprocessed', {'ms': preSw.elapsedMilliseconds});

      // 3. Wrap inputs.
      compositeInput = ort.OrtValueTensor.createTensorWithDataList(
        compositeTensor.data,
        compositeTensor.shape,
      );
      maskInput = ort.OrtValueTensor.createTensorWithDataList(
        maskTensor,
        [1, 1, inputSize, inputSize],
      );

      // 4. Resolve session input names. Harmonizer ONNX exports
      //    typically use 'composite' / 'mask' or 'image' / 'mask';
      //    we suffix-match to tolerate variants.
      final inputMap = mapInputs(
        sessionInputs: session.inputNames,
        compositeValue: compositeInput,
        maskValue: maskInput,
      );

      final inferSw = Stopwatch()..start();
      outputs = await session.runTyped(inputMap);
      inferSw.stop();
      _log.d('inference', {'ms': inferSw.elapsedMilliseconds});

      if (outputs.isEmpty || outputs.first == null) {
        throw const HarmonizerException(
          'Harmonizer returned no output tensor',
        );
      }

      // 5. Flatten the [1, 8] filter-args tensor.
      final raw = outputs.first!.value;
      final args = flattenArgs(raw);
      if (args == null || args.length != numFilterArgs) {
        throw HarmonizerException(
          'Harmonizer output shape unrecognised — expected '
          '[1, $numFilterArgs] flat, got ${args?.length} elements',
        );
      }

      total.stop();
      _log.i('run complete', {
        'totalMs': total.elapsedMilliseconds,
        'preMs': preSw.elapsedMilliseconds,
        'inferMs': inferSw.elapsedMilliseconds,
        'args': args.map((v) => v.toStringAsFixed(3)).toList(),
      });
      return HarmonizerArgs.fromList(args);
    } on HarmonizerException {
      rethrow;
    } catch (e, st) {
      total.stop();
      _log.e('run failed',
          error: e, stackTrace: st, data: {'ms': total.elapsedMilliseconds});
      throw HarmonizerException(e.toString(), cause: e);
    } finally {
      try {
        compositeInput?.release();
      } catch (e) {
        _log.w('composite input release failed',
            {'error': e.toString()});
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

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _log.i('close');
    await session.close();
  }

  // ===================================================================
  // Pure helpers — exposed for tests.
  // ===================================================================

  /// Bilinear resize a `width × height` Float32 mask to a new
  /// resolution. Mirrors the helper in
  /// `SemanticSegmentationService.bilinearResize` — duplicated so
  /// this service doesn't take a dependency on the LiteRT-only
  /// segmentation module.
  @visibleForTesting
  static Float32List bilinearResizeMask({
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

  /// Resolve session input names against composite/mask OrtValues.
  /// Harmonizer's exports typically use ('composite', 'mask') or
  /// ('image', 'mask'); the matching is suffix-based so a few
  /// naming variants drop in cleanly.
  @visibleForTesting
  static Map<String, ort.OrtValue> mapInputs({
    required List<String> sessionInputs,
    required ort.OrtValue compositeValue,
    required ort.OrtValue maskValue,
  }) {
    if (sessionInputs.length < 2) {
      throw HarmonizerException(
        'Harmonizer model has ${sessionInputs.length} inputs, '
        'expected 2 (composite + mask)',
      );
    }
    String compositeName = sessionInputs[0];
    String maskName = sessionInputs[1];
    for (final name in sessionInputs) {
      final lower = name.toLowerCase();
      if (lower == 'mask' || lower.contains('mask')) {
        maskName = name;
      } else if (lower == 'composite' ||
          lower == 'image' ||
          lower == 'input' ||
          lower.contains('composite') ||
          (lower.contains('image') && !lower.contains('mask')) ||
          (lower.contains('input') && !lower.contains('mask'))) {
        compositeName = name;
      }
    }
    return {compositeName: compositeValue, maskName: maskValue};
  }

  /// Walk a nested `[1, 8]` (or `[8]`) tensor into a flat list. The
  /// regressor head's output may include the leading batch axis or
  /// not depending on the export.
  @visibleForTesting
  static List<double>? flattenArgs(Object? raw) {
    if (raw is! List || raw.isEmpty) return null;
    List current = raw;
    // Peel the leading batch dim if present.
    if (current.first is List) {
      current = current.first as List;
    }
    final out = <double>[];
    for (final v in current) {
      if (v is num) {
        out.add(v.toDouble());
      } else {
        return null;
      }
    }
    return out;
  }
}

/// White-box filter arguments returned by the Harmonizer regressor.
/// Each field maps directly to an existing slider in the editor;
/// the consumer feeds them into `EditPipeline.appendOps()` so the
/// shader chain renders the harmonised result at full resolution.
class HarmonizerArgs {
  const HarmonizerArgs({
    required this.brightness,
    required this.contrast,
    required this.saturation,
    required this.temperature,
    required this.tint,
    required this.sharpness,
    required this.highlights,
    required this.shadows,
  });

  /// Construct from the raw 8-element float vector. Order matches
  /// the Harmonizer paper:
  ///   `[brightness, contrast, saturation, temperature, tint,
  ///    sharpness, highlights, shadows]`.
  factory HarmonizerArgs.fromList(List<double> v) {
    if (v.length != 8) {
      throw ArgumentError(
        'HarmonizerArgs.fromList expects 8 elements, got ${v.length}',
      );
    }
    return HarmonizerArgs(
      brightness: v[0],
      contrast: v[1],
      saturation: v[2],
      temperature: v[3],
      tint: v[4],
      sharpness: v[5],
      highlights: v[6],
      shadows: v[7],
    );
  }

  final double brightness;
  final double contrast;
  final double saturation;
  final double temperature;
  final double tint;
  final double sharpness;
  final double highlights;
  final double shadows;

  /// Identity (no-op) args. Useful for the silent-fallback path
  /// when the model isn't available — feeding identity args
  /// reproduces pre-XVI.54 behaviour exactly.
  static const HarmonizerArgs identity = HarmonizerArgs(
    brightness: 0,
    contrast: 0,
    saturation: 0,
    temperature: 0,
    tint: 0,
    sharpness: 0,
    highlights: 0,
    shadows: 0,
  );

  /// True when every value is within [eps] of identity. The
  /// compose service uses this to short-circuit the harmonisation
  /// step entirely when the model says "this composite is already
  /// harmonised" — saves the per-frame shader work.
  bool isApproximatelyIdentity({double eps = 1e-3}) {
    return brightness.abs() < eps &&
        contrast.abs() < eps &&
        saturation.abs() < eps &&
        temperature.abs() < eps &&
        tint.abs() < eps &&
        sharpness.abs() < eps &&
        highlights.abs() < eps &&
        shadows.abs() < eps;
  }

  /// Clamp every component to `[-clipMagnitude, +clipMagnitude]`.
  /// Out-of-distribution composites occasionally produce wild
  /// regressor output (e.g. saturation=+5.0 on heavily-clipped
  /// HDR sources); clamping keeps the rendered output reasonable.
  HarmonizerArgs clamped({double clipMagnitude = 1.0}) {
    double c(double v) => v.clamp(-clipMagnitude, clipMagnitude).toDouble();
    return HarmonizerArgs(
      brightness: c(brightness),
      contrast: c(contrast),
      saturation: c(saturation),
      temperature: c(temperature),
      tint: c(tint),
      sharpness: c(sharpness),
      highlights: c(highlights),
      shadows: c(shadows),
    );
  }
}

/// Stable model id for the Harmonizer ONNX. Used by the AI
/// bootstrap's `ModelRegistry.resolve()` call.
const String kHarmonizerModelId = 'harmonizer_eccv_2022';

class HarmonizerException implements Exception {
  const HarmonizerException(this.message, {this.cause});
  final String message;
  final Object? cause;

  @override
  String toString() {
    if (cause == null) return 'HarmonizerException: $message';
    return 'HarmonizerException: $message (caused by $cause)';
  }
}
