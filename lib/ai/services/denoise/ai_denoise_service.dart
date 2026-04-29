import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:onnxruntime_v2/onnxruntime_v2.dart' as ort;

import '../../../core/logging/app_logger.dart';
import '../../inference/image_tensor.dart';
import '../../runtime/ort_runtime.dart';
import '../bg_removal/image_io.dart';

final _log = AppLogger('AiDenoiseService');

/// Phase XVI.50 — AI-tier image denoiser.
///
/// The audit plan called for FFDNet; per the user's XVI.50 selection
/// we ship DnCNN-color (Zhang et al. 2017) as the substitute network
/// — slightly less flexible (DnCNN trains a fixed sigma; FFDNet feeds
/// sigma as an extra input plane) but its public ONNX exports are
/// far more reliable and mobile-fits. The service has no compile-time
/// dependency on which architecture the bundled model came from; any
/// `[1, 3, H, W] → [1, 3, H, W]` ONNX denoiser drops in.
///
/// ## I/O contract
///
/// **Input:** `[1, 3, inputSize, inputSize]` float32 in `[0, 1]` sRGB
/// (HWC→CHW via [ImageTensor.fromRgba]). Source is bilinearly
/// resized; the network is fully-convolutional so any multiple of 8
/// would also work, but a fixed input simplifies the pre/post path
/// and keeps inference latency predictable.
///
/// **Output:** `[1, 3, inputSize, inputSize]` float32 in `[0, 1]`
/// — clean RGB. (DnCNN-color exports trained with residual learning
/// emit `noise`, not `clean`; the [residualOutput] flag toggles
/// between the two interpretations: when true the postprocessor
/// computes `clean = input − output` instead of using `output`
/// directly. Both modes ship and the bundled-model author picks
/// which based on the export's training objective.)
///
/// ## Pipeline
///
/// 1. Decode source to RGBA (capped at 1024 px on long edge).
/// 2. Resize to [inputSize] × [inputSize] CHW float32 in `[0, 1]`.
/// 3. Single ORT inference call.
/// 4. Reshape output → CHW Float32List.
/// 5. (If [residualOutput]:) `clean = input − noise`.
/// 6. Bilinear-resize the clean tensor back to the original decoded
///    dimensions and pack to RGBA.
/// 7. Re-upload as a `ui.Image`.
///
/// Silent fallback per project convention: if the model fails to
/// load (asset missing, ORT init error), the AI coordinator never
/// instantiates the service — there's no thrown error toast for
/// users; the "Denoise (AI)" button just stays inactive.
class AiDenoiseService {
  AiDenoiseService({
    required this.session,
    this.inputSize = 1024,
    this.residualOutput = false,
  });

  /// Native input edge length the network runs at. DnCNN-color is
  /// fully-convolutional so any multiple of 8 works; 1024 px gives a
  /// good preview-resolution match for typical phone photos.
  final int inputSize;

  /// True when the bundled ONNX is trained as residual prediction
  /// (output = noise) instead of direct clean-image output. The
  /// post-processor subtracts the model's output from the input
  /// when this is set.
  final bool residualOutput;

  final OrtV2Session session;
  bool _closed = false;

  /// Run AI denoise on the source file. Returns a `ui.Image` at the
  /// decoded source dimensions with the noise pass applied.
  Future<ui.Image> denoiseFromPath(String sourcePath) async {
    if (_closed) {
      _log.w('run rejected — session closed', {'path': sourcePath});
      throw const AiDenoiseException('AiDenoiseService is closed');
    }
    final total = Stopwatch()..start();
    _log.i('run start', {
      'path': sourcePath,
      'inputs': session.inputNames,
      'outputs': session.outputNames,
      'inputSize': inputSize,
      'residualOutput': residualOutput,
    });

    ort.OrtValue? inputValue;
    List<ort.OrtValue?>? outputs;
    try {
      // 1. Decode source — capped at 1024 px to match our preview budget.
      final decoded = await BgRemovalImageIo.decodeFileToRgba(sourcePath);
      _log.d('source decoded', {'w': decoded.width, 'h': decoded.height});

      // 2. Build input tensor [1, 3, inputSize, inputSize] in [0, 1].
      final preSw = Stopwatch()..start();
      final inputTensor = ImageTensor.fromRgba(
        rgba: decoded.bytes,
        srcWidth: decoded.width,
        srcHeight: decoded.height,
        dstWidth: inputSize,
        dstHeight: inputSize,
      );
      preSw.stop();
      _log.d('preprocessed', {'ms': preSw.elapsedMilliseconds});

      // 3. Wrap input + run inference. DnCNN exports typically use
      //    'input' or 'image' as the input name; match by suffix.
      final inputName = pickInputName(session.inputNames);
      if (inputName == null) {
        throw AiDenoiseException(
          'No matching input name on session: ${session.inputNames}',
        );
      }
      inputValue = ort.OrtValueTensor.createTensorWithDataList(
        inputTensor.data,
        inputTensor.shape,
      );

      final inferSw = Stopwatch()..start();
      outputs = await session.runTyped({inputName: inputValue});
      inferSw.stop();
      _log.d('inference', {'ms': inferSw.elapsedMilliseconds});

      if (outputs.isEmpty || outputs.first == null) {
        throw const AiDenoiseException(
          'Denoise model returned no output tensor',
        );
      }

      // 4. Flatten the [1, 3, H, W] tensor.
      final raw = outputs.first!.value;
      final cleanChw = flattenChw(raw);
      if (cleanChw == null) {
        throw const AiDenoiseException(
          'Denoise output shape unrecognised — expected [1, 3, H, W]',
        );
      }

      // 5. Residual handling. Some DnCNN exports emit noise, not the
      //    clean image; subtract from the input to recover the clean.
      final denoisedChw = residualOutput
          ? subtractResidual(input: inputTensor.data, residual: cleanChw)
          : cleanChw;

      // 6. Resize back to source dimensions + pack to RGBA.
      final postSw = Stopwatch()..start();
      final rgba = chwToRgba(
        chw: denoisedChw,
        chwSize: inputSize,
        dstWidth: decoded.width,
        dstHeight: decoded.height,
      );
      postSw.stop();
      _log.d('postprocessed', {'ms': postSw.elapsedMilliseconds});

      // 7. Upload as ui.Image at the decoded dimensions.
      final image = await BgRemovalImageIo.encodeRgbaToUiImage(
        rgba: rgba,
        width: decoded.width,
        height: decoded.height,
      );
      total.stop();
      _log.i('run complete', {
        'totalMs': total.elapsedMilliseconds,
        'preMs': preSw.elapsedMilliseconds,
        'inferMs': inferSw.elapsedMilliseconds,
        'postMs': postSw.elapsedMilliseconds,
      });
      return image;
    } on AiDenoiseException {
      rethrow;
    } on BgRemovalIoException catch (e) {
      _log.w('run IO failure — rewrapping', {'message': e.message});
      throw AiDenoiseException(e.message, cause: e);
    } catch (e, st) {
      total.stop();
      _log.e('run failed',
          error: e, stackTrace: st, data: {'ms': total.elapsedMilliseconds});
      throw AiDenoiseException(e.toString(), cause: e);
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

  /// Match the session's declared input name against the common
  /// DnCNN naming conventions ('input', 'image', 'pixel_values').
  /// Falls back to the first declared name when no candidate matches
  /// — keeps the service tolerant of community ONNX exports.
  @visibleForTesting
  static String? pickInputName(List<String> names) {
    const candidates = ['input', 'image', 'pixel_values', 'sample'];
    for (final c in candidates) {
      for (final n in names) {
        final lower = n.toLowerCase();
        if (lower == c || lower.endsWith(c)) return n;
      }
    }
    return names.isEmpty ? null : names.first;
  }

  /// Walk a nested `[1, 3, H, W]` (or `[3, H, W]`) tensor into a flat
  /// CHW Float32List. Returns null when the shape doesn't match.
  @visibleForTesting
  static Float32List? flattenChw(Object? raw) {
    if (raw is! List || raw.isEmpty) return null;
    List current = raw;
    // Drop the leading batch dim if present.
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

  /// Compute `clean = input − residual` element-wise. Used when the
  /// bundled ONNX is a residual-learning DnCNN variant (output is the
  /// predicted noise, not the clean image).
  @visibleForTesting
  static Float32List subtractResidual({
    required Float32List input,
    required Float32List residual,
  }) {
    if (input.length != residual.length) {
      throw ArgumentError(
        'input length ${input.length} != residual length ${residual.length}',
      );
    }
    final out = Float32List(input.length);
    for (var i = 0; i < input.length; i++) {
      final v = input[i] - residual[i];
      out[i] = v < 0 ? 0 : (v > 1 ? 1 : v);
    }
    return out;
  }

  /// Bilinearly resample a CHW float tensor at `chwSize × chwSize`
  /// to `dstWidth × dstHeight` and pack the result as RGBA8 with
  /// fully-opaque alpha.
  @visibleForTesting
  static Uint8List chwToRgba({
    required Float32List chw,
    required int chwSize,
    required int dstWidth,
    required int dstHeight,
  }) {
    final out = Uint8List(dstWidth * dstHeight * 4);
    final hw = chwSize * chwSize;
    final yScale = chwSize > 1 ? (chwSize - 1) / (dstHeight - 1) : 0.0;
    final xScale = chwSize > 1 ? (chwSize - 1) / (dstWidth - 1) : 0.0;
    for (var y = 0; y < dstHeight; y++) {
      final sy = y * yScale;
      final y0 = sy.floor().clamp(0, chwSize - 1);
      final y1 = (y0 + 1).clamp(0, chwSize - 1);
      final wy = sy - y0;
      for (var x = 0; x < dstWidth; x++) {
        final sx = x * xScale;
        final x0 = sx.floor().clamp(0, chwSize - 1);
        final x1 = (x0 + 1).clamp(0, chwSize - 1);
        final wx = sx - x0;

        double sample(int planeOffset) {
          final v00 = chw[planeOffset + y0 * chwSize + x0];
          final v01 = chw[planeOffset + y0 * chwSize + x1];
          final v10 = chw[planeOffset + y1 * chwSize + x0];
          final v11 = chw[planeOffset + y1 * chwSize + x1];
          return (v00 * (1 - wx) + v01 * wx) * (1 - wy) +
              (v10 * (1 - wx) + v11 * wx) * wy;
        }

        final r = sample(0).clamp(0.0, 1.0) * 255;
        final g = sample(hw).clamp(0.0, 1.0) * 255;
        final b = sample(hw * 2).clamp(0.0, 1.0) * 255;
        final idx = (y * dstWidth + x) * 4;
        out[idx] = r.round();
        out[idx + 1] = g.round();
        out[idx + 2] = b.round();
        out[idx + 3] = 255;
      }
    }
    return out;
  }
}

/// Stable model id for the bundled DnCNN-color denoiser. Used by the
/// AI bootstrap's `ModelRegistry.resolve()` call.
const String kDnCnnColorModelId = 'dncnn_color_int8';

class AiDenoiseException implements Exception {
  const AiDenoiseException(this.message, {this.cause});
  final String message;
  final Object? cause;

  @override
  String toString() {
    if (cause == null) return 'AiDenoiseException: $message';
    return 'AiDenoiseException: $message (caused by $cause)';
  }
}
