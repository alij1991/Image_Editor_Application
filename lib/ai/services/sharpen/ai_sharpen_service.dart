import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:onnxruntime_v2/onnxruntime_v2.dart' as ort;

import '../../../core/logging/app_logger.dart';
import '../../inference/image_tensor.dart';
import '../../inference/wet_dry_blend.dart';
import '../../runtime/ort_runtime.dart';
import '../bg_removal/image_io.dart';

final _log = AppLogger('AiSharpenService');

/// Phase XVI.55 (XVI.80 — native-resolution refactor) — AI-tier
/// image deblur / sharpen.
///
/// The audit plan called for a small deblur ONNX following the same
/// scaffold pattern as super-resolution. Per the XVI.55 model
/// selection we ship NAFNet (Chen et al. 2022, ECCV — the
/// "Nonlinear Activation Free Network").
///
/// * Single ~92 MB FP32 ONNX (OpenCV's deblurring_nafnet_2025may).
/// * 33.71 dB PSNR on GoPro deblur, ahead of MIMO-UNet+ (32.45 dB)
///   and competitive with Restormer at a fraction of the cost.
/// * Fully-convolutional — input dims are `[N, 3, H, W]` with H/W
///   dynamic (any multiple of 8). Verified XVI.80 by probing the
///   onnx with onnxruntime 1.23.2.
///
/// ## XVI.80 — the native-resolution fix
///
/// Pre-XVI.80 the service hard-coded a 512×512 SQUARE input — for a
/// 4:3 source (1024×768) this meant bilinear-resizing to 512×512
/// (catastrophic blur from both downsampling AND aspect-ratio
/// destruction), running NAFNet (which removed essentially no blur
/// because most of it was resize-introduced rather than the source
/// blur the network was trained on), then resizing back to 1024×768.
/// Net result: the sharpen pass made photos VISIBLY BLURRIER than
/// the input. Discovered XVI.80 via device-test screenshots.
///
/// XVI.80 routes the source through at its NATIVE decoded
/// dimensions: target H/W are computed from `decoded.width/height`
/// rounded down to the nearest multiple of 8 (NAFNet's stride
/// constraint). Capped at [maxInputDim] (default 1024) on the long
/// edge so a 4K source doesn't blow up the inference RAM budget.
///
/// ## I/O contract
///
/// **Input:** `[1, 3, H, W]` float32 in `[0, 1]` sRGB (HWC→CHW via
/// [ImageTensor.fromRgba]). H, W are computed per-call.
///
/// **Output:** `[1, 3, H, W]` float32 in `[0, 1]` — clean RGB.
/// NAFNet (and most modern restoration nets) emits the CLEAN image
/// directly, not a residual. There is intentionally no
/// `residualOutput` flag here — adding one would invite a subtle
/// double-subtract bug for a network family that doesn't need it.
///
/// ## Pipeline
///
/// 1. Decode source to RGBA (capped at 1024 px on long edge).
/// 2. Compute (targetW, targetH) = round_down_to_8(decoded dims),
///    capped at [maxInputDim] long edge.
/// 3. Resize source to (targetW × targetH) CHW float32 in `[0, 1]`.
/// 4. Single ORT inference call.
/// 5. Reshape output → CHW Float32List at (targetW, targetH).
/// 6. Bilinear-resize the clean tensor back to the original decoded
///    dimensions and pack to RGBA. When target ≈ decoded this is a
///    near-identity copy (only quantization-to-/8 rounding).
/// 7. Re-upload as a `ui.Image`.
///
/// Silent fallback per project convention: if the model fails to
/// load (asset missing, ORT init error), the AI coordinator never
/// instantiates the service — the "Sharpen (AI)" button just stays
/// inactive. No toast.
class AiSharpenService {
  AiSharpenService({
    required this.session,
    this.maxInputDim = 1024,
  });

  /// XVI.80 — max long-edge dimension fed to the network. NAFNet is
  /// fully convolutional so any multiple of 8 works; capping at
  /// 1024 keeps inference RAM bounded on phone CPUs (a 1024×1024
  /// activation tensor at 32 channels = 128 MB peak). The actual
  /// target W/H per call is computed from the decoded image's
  /// aspect ratio, rounded down to the nearest 8, with the long
  /// edge clamped to this value.
  final int maxInputDim;

  final OrtV2Session session;
  bool _closed = false;

  /// XVI.80 — compute the (targetW, targetH) we'll feed NAFNet for
  /// a `srcWidth × srcHeight` decoded image. Preserves aspect
  /// ratio; rounds down to multiples of 8 (NAFNet's stride);
  /// clamps the long edge to [maxInputDim]. Returns at least 8×8
  /// to satisfy the stride constraint even for degenerate inputs.
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
    // Round down to /8 (NAFNet stride). Minimum 8 to avoid 0-dim.
    w = (w ~/ 8) * 8;
    h = (h ~/ 8) * 8;
    if (w < 8) w = 8;
    if (h < 8) h = 8;
    return (w, h);
  }

  /// Run AI sharpen on the source file. Returns a `ui.Image` at the
  /// decoded source dimensions with the deblur pass applied.
  ///
  /// [strength] is the XVI.102 wet/dry blend ratio between the
  /// source pixels and the deblurred pixels (`out = src * (1 - s) +
  /// deblur * s`). Defaults to [kDefaultDeblurStrength] (0.55) so
  /// running AI Deblur on an already-sharp photo doesn't visibly
  /// soften it. Set to `1.0` for the pre-XVI.102 behaviour (full
  /// model output, aggressive softening on clean inputs).
  Future<ui.Image> sharpenFromPath(
    String sourcePath, {
    double strength = kDefaultDeblurStrength,
  }) async {
    if (_closed) {
      _log.w('run rejected — session closed', {'path': sourcePath});
      throw const AiSharpenException('AiSharpenService is closed');
    }
    final total = Stopwatch()..start();
    _log.i('run start', {
      'path': sourcePath,
      'inputs': session.inputNames,
      'outputs': session.outputNames,
      'maxInputDim': maxInputDim,
    });

    ort.OrtValue? inputValue;
    List<ort.OrtValue?>? outputs;
    try {
      // 1. Decode source — capped at 1024 px to match our preview budget.
      final decoded = await BgRemovalImageIo.decodeFileToRgba(sourcePath);
      _log.d('source decoded', {'w': decoded.width, 'h': decoded.height});

      // 2. Compute the network-input dims that preserve aspect ratio
      //    (rounded to /8) — XVI.80 fix. For a 1024×768 source this
      //    yields 1024×768 (identity) instead of the legacy 512×512
      //    square that destroyed both detail AND aspect ratio.
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

      // 3. Wrap input + run inference. NAFNet exports typically use
      //    'input' or 'image' as the input name; match by suffix.
      final inputName = pickInputName(session.inputNames);
      if (inputName == null) {
        throw AiSharpenException(
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
        throw const AiSharpenException(
          'Sharpen model returned no output tensor',
        );
      }

      // 4. Flatten the [1, 3, H, W] tensor.
      final raw = outputs.first!.value;
      final cleanChw = flattenChw(raw);
      if (cleanChw == null) {
        throw const AiSharpenException(
          'Sharpen output shape unrecognised — expected [1, 3, H, W]',
        );
      }

      // 5. Resize back to source dimensions + pack to RGBA. XVI.80:
      //    chwToRgba now takes separate W/H (was square-only). When
      //    target == decoded (the common case after the native-
      //    resolution refactor), this is essentially an identity
      //    copy — only the modulo-8 rounding might trim a few
      //    rows/columns that bilinearly resample back.
      final postSw = Stopwatch()..start();
      final rgbaModel = chwToRgba(
        chw: cleanChw,
        chwWidth: targetW,
        chwHeight: targetH,
        dstWidth: decoded.width,
        dstHeight: decoded.height,
      );
      postSw.stop();
      _log.d('postprocessed', {'ms': postSw.elapsedMilliseconds});

      // 5a. XVI.102 — wet/dry blend with the source. NAFNet is a
      //     deblur model that learned all inputs contain residual
      //     blur to undo; on a sharp portrait it visibly softens
      //     the face. A fractional blend keeps source sharpness on
      //     clean inputs while still helping on genuinely blurred
      //     ones.
      final rgba = blendWetDry(
        source: decoded.bytes,
        processed: rgbaModel,
        strength: strength,
      );
      _log.d('wet/dry blended', {'strength': strength});

      // 6. Upload as ui.Image at the decoded dimensions.
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
    } on AiSharpenException {
      rethrow;
    } on BgRemovalIoException catch (e) {
      _log.w('run IO failure — rewrapping', {'message': e.message});
      throw AiSharpenException(e.message, cause: e);
    } catch (e, st) {
      total.stop();
      _log.e('run failed',
          error: e, stackTrace: st, data: {'ms': total.elapsedMilliseconds});
      throw AiSharpenException(e.toString(), cause: e);
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
  /// NAFNet / restoration-net naming conventions ('input', 'image',
  /// 'pixel_values', 'sample', 'lq' for low-quality input). Falls
  /// back to the first declared name when no candidate matches —
  /// keeps the service tolerant of community ONNX exports.
  @visibleForTesting
  static String? pickInputName(List<String> names) {
    const candidates = ['input', 'image', 'pixel_values', 'sample', 'lq'];
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

  /// Bilinearly resample a CHW float tensor at `chwWidth × chwHeight`
  /// to `dstWidth × dstHeight` and pack the result as RGBA8 with
  /// fully-opaque alpha.
  ///
  /// XVI.80 — the legacy signature used a single `chwSize` and
  /// silently assumed square. After the native-resolution refactor
  /// the network's output is rectangular (matches decoded aspect
  /// ratio rounded to /8), so width and height are passed
  /// separately.
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

/// Stable model id for the downloaded NAFNet deblur ONNX (OpenCV's
/// 2025-05 export, FP32). XVI.64 renamed this from
/// `nafnet_32_deblur_fp16` once the actual published file was
/// verified — no community FP16 NAFNet ONNX exists. Used by the AI
/// bootstrap's `ModelRegistry.resolve()` call.
const String kAiSharpenModelId = 'nafnet_deblur_2025may_fp32';

class AiSharpenException implements Exception {
  const AiSharpenException(this.message, {this.cause});
  final String message;
  final Object? cause;

  @override
  String toString() {
    if (cause == null) return 'AiSharpenException: $message';
    return 'AiSharpenException: $message (caused by $cause)';
  }
}
