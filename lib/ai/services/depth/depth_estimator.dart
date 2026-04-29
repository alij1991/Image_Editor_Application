import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:onnxruntime_v2/onnxruntime_v2.dart' as ort;

import '../../../core/logging/app_logger.dart';
import '../../inference/image_tensor.dart';
import '../../runtime/ort_runtime.dart';
import '../bg_removal/image_io.dart';

final _log = AppLogger('DepthEstimator');

/// Phase XVI.40 — Depth-Anything-V2-Small (INT8 quantised) monocular
/// depth estimator. Drives the depth-aware Lens Blur shader by
/// producing a single-channel inverse-depth map (higher values =
/// closer to camera) the size of the source image.
///
/// Inputs (float32):
///   - `pixel_values`: `[1, 3, H, W]` ImageNet-normalised RGB
///     (mean=[0.485, 0.456, 0.406], std=[0.229, 0.224, 0.225]).
///
/// Outputs (float32):
///   - `predicted_depth`: `[1, H, W]` — relative inverse depth.
///     Network is scale- and shift-invariant, so the consumer
///     normalises to `[0, 1]` per-image before sampling.
///
/// The service runs at a fixed 518×518 input (multiple of the model's
/// patch size 14) and bilinearly upsamples the output back to the
/// source resolution. The shader's depth sampler does the final
/// per-pixel lookup against this map.
///
/// Silent fallback: if the bundled model fails to load (asset
/// missing, ORT init error), the service constructor is never
/// reached — `LensBlurController` is responsible for guarding the
/// pass-builder so the rest of the editor keeps rendering.
class DepthEstimator {
  DepthEstimator({required this.session});

  /// Model input edge length. 518 px is the published size for
  /// Depth-Anything-V2-Small (the patch tokeniser uses 14×14 patches,
  /// so any input must be a multiple of 14; 518 = 37×14).
  static const int inputSize = 518;

  /// ImageNet preprocessing constants. Same values used by every
  /// HuggingFace `transformers.image_processing` checkpoint trained on
  /// the standard ImageNet pipeline.
  static const List<double> imageNetMean = [0.485, 0.456, 0.406];
  static const List<double> imageNetStd = [0.229, 0.224, 0.225];

  final OrtV2Session session;
  bool _closed = false;

  /// Run depth estimation on the source file. Returns a single-channel
  /// `ui.Image` where the red channel carries the normalised inverse-
  /// depth value `[0, 1]` (higher = closer). The G/B channels carry the
  /// same value so any sampling format works; alpha is opaque.
  ///
  /// The returned image has the source's downscaled dimensions
  /// (capped at 1024 px on the long edge per [BgRemovalImageIo]). The
  /// shader resamples it to canvas resolution as needed.
  Future<DepthMap> estimateDepthFromPath(String sourcePath) async {
    if (_closed) {
      _log.w('run rejected — session closed', {'path': sourcePath});
      throw const DepthEstimationException('DepthEstimator is closed');
    }
    final total = Stopwatch()..start();
    _log.i('run start', {
      'path': sourcePath,
      'inputs': session.inputNames,
      'outputs': session.outputNames,
    });

    final toRelease = <ort.OrtValue?>[];
    List<ort.OrtValue?>? outputs;
    try {
      // 1. Decode source.
      final decoded = await BgRemovalImageIo.decodeFileToRgba(sourcePath);
      _log.d('source decoded', {'w': decoded.width, 'h': decoded.height});

      // 2. Build input tensor [1, 3, 518, 518] with ImageNet
      //    normalization. The network is scale-invariant so cropping
      //    behaviour at non-square inputs (we letterbox via stretch
      //    here) is not load-bearing — the depth at every pixel is
      //    relative to the rest of the image regardless.
      final preSw = Stopwatch()..start();
      final tensor = ImageTensor.fromRgba(
        rgba: decoded.bytes,
        srcWidth: decoded.width,
        srcHeight: decoded.height,
        dstWidth: inputSize,
        dstHeight: inputSize,
        mean: imageNetMean,
        std: imageNetStd,
      );
      preSw.stop();
      _log.d('preprocessed', {'ms': preSw.elapsedMilliseconds});

      // 3. Wrap input. ONNX exports of Depth-Anything-V2 use either
      //    'pixel_values' or 'image' / 'input' as the input name —
      //    match by suffix to tolerate variants.
      final inputName = _findInput(session.inputNames, const [
        'pixel_values',
        'image',
        'input',
      ]);
      if (inputName == null) {
        throw DepthEstimationException(
          'No matching input name on session: ${session.inputNames}',
        );
      }
      final inputValue = ort.OrtValueTensor.createTensorWithDataList(
        tensor.data,
        tensor.shape,
      );
      toRelease.add(inputValue);

      // 4. Inference. The output name is typically 'predicted_depth';
      //    fall back to the full output list when not declared.
      final outputName = _findOutput(session.outputNames, const [
        'predicted_depth',
        'depth',
        'output',
      ]);
      final inferSw = Stopwatch()..start();
      if (outputName != null) {
        outputs = await session.runTyped(
          {inputName: inputValue},
          outputNames: [outputName],
        );
      } else {
        outputs = await session.runTyped({inputName: inputValue});
      }
      inferSw.stop();
      _log.d('inference', {
        'ms': inferSw.elapsedMilliseconds,
        'outputName': outputName ?? 'outputs[0]',
      });

      if (outputs.isEmpty || outputs.first == null) {
        throw const DepthEstimationException(
          'Depth model returned no output tensor',
        );
      }

      // 5. Flatten the output to a [H × W] Float32List. Most exports
      //    return [1, H, W] but [1, 1, H, W] also occurs.
      final raw = outputs.first!.value;
      final flat = _flattenDepth(raw);
      if (flat == null) {
        throw const DepthEstimationException(
          'Depth output shape unrecognised',
        );
      }

      // 6. Min-max normalise to [0, 1]. Depth-Anything-V2 emits
      //    relative inverse depth that's scale- and shift-invariant,
      //    so per-image normalisation is the standard postproc.
      final postSw = Stopwatch()..start();
      final normalised = _minMaxNormalise(flat.data);
      // 7. Convert [H × W] floats to RGBA grayscale. We copy the
      //    depth into all three channels so the shader's `.r` sample
      //    works regardless of upload format.
      final rgba = _depthToRgba(normalised, flat.width, flat.height);
      // 8. Upload as a ui.Image at the model's output resolution.
      //    The shader resamples this to canvas size.
      final depthImage = await BgRemovalImageIo.encodeRgbaToUiImage(
        rgba: rgba,
        width: flat.width,
        height: flat.height,
      );
      postSw.stop();
      total.stop();
      _log.i('run complete', {
        'totalMs': total.elapsedMilliseconds,
        'preMs': preSw.elapsedMilliseconds,
        'inferMs': inferSw.elapsedMilliseconds,
        'postMs': postSw.elapsedMilliseconds,
        'mapW': flat.width,
        'mapH': flat.height,
      });
      return DepthMap(image: depthImage);
    } on DepthEstimationException {
      rethrow;
    } on BgRemovalIoException catch (e) {
      _log.w('run IO failure — rewrapping', {'message': e.message});
      throw DepthEstimationException(e.message, cause: e);
    } catch (e, st) {
      total.stop();
      _log.e('run failed',
          error: e, stackTrace: st, data: {'ms': total.elapsedMilliseconds});
      throw DepthEstimationException(e.toString(), cause: e);
    } finally {
      for (final v in toRelease) {
        try {
          v?.release();
        } catch (e) {
          _log.w('input release failed', {'error': e.toString()});
        }
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

  /// Test-visible helper: run the same name-matching the production
  /// path uses, against a synthetic name list.
  @visibleForTesting
  static String? findInputForTest(
    List<String> inputs,
    List<String> candidates,
  ) =>
      _findInput(inputs, candidates);

  @visibleForTesting
  static String? findOutputForTest(
    List<String> outputs,
    List<String> candidates,
  ) =>
      _findOutput(outputs, candidates);

  /// Test-visible helper: min-max normalise a float buffer to `[0, 1]`.
  @visibleForTesting
  static Float32List minMaxNormaliseForTest(Float32List src) =>
      _minMaxNormalise(src);

  /// Test-visible helper: pack a normalised depth field into RGBA.
  @visibleForTesting
  static Uint8List depthToRgbaForTest(
    Float32List normalised,
    int width,
    int height,
  ) =>
      _depthToRgba(normalised, width, height);

  static String? _findInput(List<String> names, List<String> candidates) {
    for (final c in candidates) {
      for (final n in names) {
        final lower = n.toLowerCase();
        if (lower == c || lower.endsWith(c)) return n;
      }
    }
    // Fallback: first input.
    return names.isEmpty ? null : names.first;
  }

  static String? _findOutput(List<String> names, List<String> candidates) {
    for (final c in candidates) {
      for (final n in names) {
        final lower = n.toLowerCase();
        if (lower == c || lower.endsWith(c)) return n;
      }
    }
    return null;
  }

  /// Walk a nested list tensor into a flat Float32List + dimensions.
  /// Tolerates the common Depth-Anything output shapes:
  ///   - `[1, H, W]`    → 3D, drop batch
  ///   - `[1, 1, H, W]` → 4D, drop two leading dims
  ///   - `[H, W]`       → 2D directly
  static _FlatDepth? _flattenDepth(Object? raw) {
    if (raw is! List || raw.isEmpty) return null;
    List current = raw;
    // Drop leading singletons until we hit a 2D HxW grid.
    while (current.isNotEmpty &&
        current.first is List &&
        (current.first as List).isNotEmpty &&
        (current.first as List).first is List) {
      current = current.first as List;
    }
    if (current.isEmpty || current.first is! List) return null;
    final height = current.length;
    final firstRow = current.first as List;
    final width = firstRow.length;
    if (width == 0) return null;
    final out = Float32List(height * width);
    for (int y = 0; y < height; y++) {
      final row = current[y];
      if (row is! List || row.length != width) return null;
      for (int x = 0; x < width; x++) {
        final v = row[x];
        if (v is num) {
          out[y * width + x] = v.toDouble();
        }
      }
    }
    return _FlatDepth(out, width, height);
  }

  /// Min-max normalise a raw inverse-depth field to `[0, 1]`. Returns
  /// the source unchanged when min ≈ max (degenerate input).
  static Float32List _minMaxNormalise(Float32List src) {
    if (src.isEmpty) return src;
    var lo = src[0];
    var hi = src[0];
    for (var i = 1; i < src.length; i++) {
      final v = src[i];
      if (v < lo) lo = v;
      if (v > hi) hi = v;
    }
    final range = hi - lo;
    if (range < 1e-6) {
      // Degenerate — every pixel reports the same depth. Return a
      // uniform 0.5 field so the lens blur effectively no-ops.
      return Float32List.fromList(List.filled(src.length, 0.5));
    }
    final out = Float32List(src.length);
    for (var i = 0; i < src.length; i++) {
      out[i] = ((src[i] - lo) / range).clamp(0.0, 1.0).toDouble();
    }
    return out;
  }

  /// Convert a normalised depth field to RGBA. Each depth value lands
  /// in all three colour channels (so any sampling format reads it
  /// consistently); alpha is fully opaque.
  static Uint8List _depthToRgba(
    Float32List normalised,
    int width,
    int height,
  ) {
    final out = Uint8List(width * height * 4);
    for (var i = 0; i < normalised.length; i++) {
      final byte = (normalised[i] * 255).round().clamp(0, 255);
      final j = i * 4;
      out[j] = byte;
      out[j + 1] = byte;
      out[j + 2] = byte;
      out[j + 3] = 255;
    }
    return out;
  }
}

/// Result of a depth estimation run. Wraps the depth map [ui.Image]
/// so call sites have a typed handle and can release it cleanly.
class DepthMap {
  const DepthMap({required this.image});

  /// Single-channel grayscale depth map (red carries the value, G/B
  /// duplicated, alpha opaque). Width/height match the source's
  /// downscaled dimensions.
  final ui.Image image;

  int get width => image.width;
  int get height => image.height;

  /// Dispose the underlying [ui.Image] when the caller no longer
  /// needs it.
  void dispose() {
    image.dispose();
  }
}

class _FlatDepth {
  const _FlatDepth(this.data, this.width, this.height);
  final Float32List data;
  final int width;
  final int height;
}

class DepthEstimationException implements Exception {
  const DepthEstimationException(this.message, {this.cause});
  final String message;
  final Object? cause;

  @override
  String toString() {
    if (cause == null) return 'DepthEstimationException: $message';
    return 'DepthEstimationException: $message (caused by $cause)';
  }
}

/// Stable model id for the bundled depth model. Used by the
/// `ModelRegistry.resolve()` call in the AI bootstrap.
const String kDepthAnythingV2SmallModelId = 'depth_anything_v2_small_int8';
