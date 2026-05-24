import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:onnxruntime_v2/onnxruntime_v2.dart' as ort;

import '../../../core/logging/app_logger.dart';
import '../../inference/image_tensor.dart';
import '../../runtime/ort_runtime.dart';
import '../bg_removal/image_io.dart';

final _log = AppLogger('AiDenoiseService');

/// Phase XVI.50 (XVI.82 — native-resolution refactor) — AI-tier
/// image denoiser.
///
/// The audit plan called for FFDNet; per the user's XVI.50 selection
/// we ship DnCNN-color (Zhang et al. 2017) as the substitute network
/// — slightly less flexible (DnCNN trains a fixed sigma; FFDNet feeds
/// sigma as an extra input plane) but its public ONNX exports are
/// far more reliable and mobile-fits. The service has no compile-time
/// dependency on which architecture the bundled model came from; any
/// `[1, 3, H, W] → [1, 3, H, W]` ONNX denoiser drops in.
///
/// ## XVI.82 — the native-resolution fix
///
/// Pre-XVI.82 the service hard-coded `inputSize=1024` and ran the
/// network on a 1024×1024 SQUARE. For a 1024×768 source that meant
/// bilinear-stretching the height from 768 → 1024 (introducing
/// resampling blur that competed with the denoise pass for visible
/// detail), running DnCNN, then resizing back to 1024×768. Same
/// shape as the XVI.80 AI Sharpen bug.
///
/// XVI.82 swaps `inputSize` for `maxInputDim` and computes the
/// actual target H/W from the decoded source dims rounded down to
/// /8 (DnCNN-color is fully convolutional — any /8 multiple works,
/// per the manifest comment). Aspect ratio is preserved; long edge
/// is clamped to [maxInputDim] (default 1024) to bound inference RAM.
///
/// ## I/O contract
///
/// **Input:** `[1, 3, H, W]` float32 in `[0, 1]` sRGB (HWC→CHW via
/// [ImageTensor.fromRgba]). H, W are computed per-call.
///
/// **Output:** `[1, 3, H, W]` float32 in `[0, 1]` — clean RGB.
/// DnCNN-color exports trained with residual learning emit `noise`,
/// not `clean`; the [residualOutput] flag toggles between the two
/// interpretations: when true the postprocessor computes
/// `clean = input − output` instead of using `output` directly.
/// Both modes ship and the bundled-model author picks which based
/// on the export's training objective.
///
/// ## Pipeline
///
/// 1. Decode source to RGBA (capped at 1024 px on long edge).
/// 2. Compute (targetW, targetH) = round_down_to_8(decoded dims),
///    capped at [maxInputDim] long edge.
/// 3. Resize source to (targetW × targetH) CHW float32 in `[0, 1]`.
/// 4. Single ORT inference call.
/// 5. Reshape output → CHW Float32List at (targetW, targetH).
/// 6. (If [residualOutput]:) `clean = input − noise`.
/// 7. Bilinear-resize the clean tensor back to the original decoded
///    dimensions and pack to RGBA. When target ≈ decoded this is a
///    near-identity copy.
/// 8. Re-upload as a `ui.Image`.
///
/// Silent fallback per project convention: if the model fails to
/// load (asset missing, ORT init error), the AI coordinator never
/// instantiates the service — there's no thrown error toast for
/// users; the "Denoise (AI)" button just stays inactive.
class AiDenoiseService {
  AiDenoiseService({
    required this.session,
    this.maxInputDim = 1024,
    this.residualOutput = false,
  });

  /// XVI.82 — max long-edge dimension fed to the network. DnCNN is
  /// fully convolutional so any multiple of 8 works; capping at 1024
  /// keeps inference RAM bounded on phone CPUs. The actual target
  /// W/H per call is computed from the decoded image's aspect ratio,
  /// rounded down to the nearest 8, with the long edge clamped to
  /// this value.
  final int maxInputDim;

  /// True when the bundled ONNX is trained as residual prediction
  /// (output = noise) instead of direct clean-image output. The
  /// post-processor subtracts the model's output from the input
  /// when this is set.
  final bool residualOutput;

  final OrtV2Session session;
  bool _closed = false;

  /// XVI.82 — compute the (targetW, targetH) we'll feed DnCNN for
  /// a `srcWidth × srcHeight` decoded image. Preserves aspect ratio;
  /// rounds down to multiples of 8; clamps the long edge to
  /// [maxInputDim]. Returns at least 8×8 for degenerate inputs.
  /// Same shape as AiSharpenService.computeTargetDims — kept as a
  /// per-service static so the two evolve independently if NAFNet's
  /// constraints diverge from DnCNN's.
  @visibleForTesting
  static (int width, int height) computeTargetDims({
    required int srcWidth,
    required int srcHeight,
    required int maxInputDim,
  }) {
    if (srcWidth <= 0 || srcHeight <= 0) return (8, 8);
    final longEdge = srcWidth > srcHeight ? srcWidth : srcHeight;
    final scale = longEdge > maxInputDim ? maxInputDim / longEdge : 1.0;
    var w = (srcWidth * scale).floor();
    var h = (srcHeight * scale).floor();
    w = (w ~/ 8) * 8;
    h = (h ~/ 8) * 8;
    if (w < 8) w = 8;
    if (h < 8) h = 8;
    return (w, h);
  }

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
      'maxInputDim': maxInputDim,
      'residualOutput': residualOutput,
    });

    ort.OrtValue? inputValue;
    List<ort.OrtValue?>? outputs;
    try {
      // 1. Decode source — capped at 1024 px to match our preview budget.
      final decoded = await BgRemovalImageIo.decodeFileToRgba(sourcePath);
      _log.d('source decoded', {'w': decoded.width, 'h': decoded.height});

      // 2. Compute network-input dims that preserve aspect ratio,
      //    rounded down to /8 (XVI.82). For a 1024×768 source this
      //    yields 1024×768 — true identity preprocess instead of the
      //    legacy 1024×1024 square that stretched height into width.
      final (targetW, targetH) = computeTargetDims(
        srcWidth: decoded.width,
        srcHeight: decoded.height,
        maxInputDim: maxInputDim,
      );
      _log.d('target dims', {
        'targetW': targetW,
        'targetH': targetH,
        'srcW': decoded.width,
        'srcH': decoded.height,
      });

      // 3. Build input tensor [1, 3, targetH, targetW] in [0, 1].
      final preSw = Stopwatch()..start();
      final inputTensor = ImageTensor.fromRgba(
        rgba: decoded.bytes,
        srcWidth: decoded.width,
        srcHeight: decoded.height,
        dstWidth: targetW,
        dstHeight: targetH,
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

      // 7. Resize back to source dimensions + pack to RGBA. XVI.82:
      //    chwToRgba now takes separate W/H (was square-only). When
      //    target == decoded (the common case after the native-
      //    resolution refactor), this is essentially an identity
      //    copy — only the modulo-8 rounding might trim a few
      //    rows/columns that bilinearly resample back.
      final postSw = Stopwatch()..start();
      final rgba = chwToRgba(
        chw: denoisedChw,
        chwWidth: targetW,
        chwHeight: targetH,
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

  /// Bilinearly resample a CHW float tensor at `chwWidth × chwHeight`
  /// to `dstWidth × dstHeight` and pack the result as RGBA8 with
  /// fully-opaque alpha.
  ///
  /// XVI.82 — the legacy signature used a single `chwSize` and
  /// silently assumed square. After the native-resolution refactor
  /// the network's output is rectangular (matches decoded aspect
  /// ratio rounded to /8), so width and height are passed
  /// separately. Mirrors the XVI.80 sharpen-service signature.
  @visibleForTesting
  static Uint8List chwToRgba({
    required Float32List chw,
    required int chwWidth,
    required int chwHeight,
    required int dstWidth,
    required int dstHeight,
  }) {
    final out = Uint8List(dstWidth * dstHeight * 4);
    final hw = chwWidth * chwHeight;
    final yScale = chwHeight > 1 && dstHeight > 1
        ? (chwHeight - 1) / (dstHeight - 1)
        : 0.0;
    final xScale = chwWidth > 1 && dstWidth > 1
        ? (chwWidth - 1) / (dstWidth - 1)
        : 0.0;
    for (var y = 0; y < dstHeight; y++) {
      final sy = y * yScale;
      final y0 = sy.floor().clamp(0, chwHeight - 1);
      final y1 = (y0 + 1).clamp(0, chwHeight - 1);
      final wy = sy - y0;
      for (var x = 0; x < dstWidth; x++) {
        final sx = x * xScale;
        final x0 = sx.floor().clamp(0, chwWidth - 1);
        final x1 = (x0 + 1).clamp(0, chwWidth - 1);
        final wx = sx - x0;

        double sample(int planeOffset) {
          final v00 = chw[planeOffset + y0 * chwWidth + x0];
          final v01 = chw[planeOffset + y0 * chwWidth + x1];
          final v10 = chw[planeOffset + y1 * chwWidth + x0];
          final v11 = chw[planeOffset + y1 * chwWidth + x1];
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

/// Stable model id for the bundled DnCNN-color denoiser (deepinv
/// DnCNN-20 variant — depth=20, no-BN, residual-add inside the
/// forward). XVI.65 renamed this from `dncnn_color_int8` once the
/// actual exported file was verified — the published ONNX is FP32
/// not INT8, the architecture is depth-20 not the canonical 17,
/// and the model emits the clean image direct rather than a noise
/// residual ([residualOutput] should be `false`, the default).
/// Used by the AI bootstrap's `ModelRegistry.resolve()` call.
const String kDnCnnColorModelId = 'dncnn_deepinv_color_fp32';

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
