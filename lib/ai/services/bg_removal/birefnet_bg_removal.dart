import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:onnxruntime_v2/onnxruntime_v2.dart' as ort;

import '../../../core/logging/app_logger.dart';
import '../../inference/image_tensor.dart';
import '../../inference/mask_stats.dart';
import '../../inference/mask_to_alpha.dart';
import '../../runtime/ort_runtime.dart';
import '../compose_on_bg/compose_edge_refine.dart';
import 'bg_removal_strategy.dart';
import 'image_io.dart';

final _log = AppLogger('BiRefNetBgRemoval');

/// Phase XVI.67 — BiRefNet-Lite high-resolution matter (Zheng et al.
/// 2024 — github.com/ZhengPeng7/BiRefNet).
///
/// The "Premium" tier in the bg-removal picker alongside RMBG.
/// BiRefNet's bilateral reference features push matte quality
/// noticeably ahead of RMBG-1.4 / U²-Net / MODNet on hair, fur,
/// transparency, and thin geometry (jewellery, grass blades, wire).
/// On the standard DIS5K benchmark BiRefNet-Lite scores S_α=0.872 vs
/// RMBG-1.4's S_α≈0.838 (≈3 points lift); the qualitative gap is
/// even larger on long hair and net-pattern fabrics where RMBG
/// produces a softened "blurry alpha" transition band.
///
/// The standard published variants:
///
///   * **BiRefNet** (full, Swin-Large backbone) — 1024² input,
///     ~880 MB FP32. Slowest, highest quality.
///   * **BiRefNet_lite** (Swin-Tiny backbone) — 1024² input, ~178 MB
///     FP32. The mobile sweet spot — shipped HERE.
///   * **BiRefNet-portrait** — 2048² input, portrait-specialised
///     ~220 MB. Higher-resolution matte for portrait shots.
///   * **BiRefNet_HR** — 2048² input, general high-resolution
///     ~880 MB.
///
/// We ship BiRefNet_lite as the default download. The service reads
/// the input shape from the ONNX session at load time so a swap to
/// any of the other variants (HR, portrait) needs only a manifest
/// pin update — no code change.
///
/// ## I/O contract
///
/// **Input:** `[1, 3, inputSize, inputSize]` float32, ImageNet-
/// normalised (mean=[0.485,0.456,0.406], std=[0.229,0.224,0.225]).
/// The community ONNX exports tag the input as `'input_image'` or
/// `'pixel_values'`; the service falls back to the first declared
/// name when neither candidate matches.
///
/// **Output:** `[1, 1, inputSize, inputSize]` float32 **raw logits**
/// (the onnx-community export does NOT bake in sigmoid). The service
/// applies sigmoid in [_sigmoidInPlace] before the mask is blended.
/// Verified against the `transformers.js` reference snippet in the
/// model card which explicitly calls `output_image[0].sigmoid()`.
///
/// The cutout flow mirrors RmbgBgRemoval (Phase XVI.49 → XVI.66c):
///   1. Decode source at native quality (4096-long-edge cap).
///   2. Bilinear-resize to inputSize × inputSize, ImageNet-normalise.
///   3. Run ORT inference → alpha mask at inputSize².
///   4. Bilinear-upsample mask + blend into the full-res RGBA.
///   5. Edge-refine with the upscale-scaled decontam kernel
///      (matte→source upscale factor × 2).
///   6. Encode as `ui.Image` at full resolution.
///
/// Ownership of the [session] transfers to this strategy — [close]
/// releases it.
class BiRefNetBgRemoval implements BgRemovalStrategy {
  BiRefNetBgRemoval({
    required this.session,
    this.inputSize = kDefaultInputSize,
    this.edgeFeatherPx = kEdgeFeatherPx,
  });

  /// BiRefNet_lite's native input size. The HR / portrait variants
  /// retrain at 2048 — pass that here if you swap the manifest pin.
  static const int kDefaultInputSize = 1024;

  /// Edge feather radius (px) applied to the BiRefNet output by
  /// [ComposeEdgeRefine.apply]. 1.0 px is enough to soften the
  /// already-clean BiRefNet edge without losing the model's
  /// signature hair detail. RMBG uses 1.5 — the slightly tighter
  /// value here reflects BiRefNet's sharper native edge.
  static const double kEdgeFeatherPx = 1.0;

  final int inputSize;
  final double edgeFeatherPx;
  final OrtV2Session session;
  bool _closed = false;

  @override
  BgRemovalStrategyKind get kind => BgRemovalStrategyKind.birefnetLite;

  @override
  Future<ui.Image> removeBackgroundFromPath(String sourcePath) async {
    if (_closed) {
      _log.w('run rejected — session closed', {'path': sourcePath});
      throw const BgRemovalException(
        'BiRefNetBgRemoval is closed',
        kind: BgRemovalStrategyKind.birefnetLite,
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
      // 1. Decode source at PREVIEW-QUALITY resolution (2048
      //    long edge), not native (4096). Phase XVI.73 backed
      //    this down after a user OOM at the 3376 MB iOS app
      //    limit: BiRefNet on iOS-pinned ORT 1.23.0 can only
      //    load via the graph-optimisation-disabled fallback
      //    (see XVI.70 + XVI.72), which means no operator
      //    fusion + no memory planning at inference. Combined
      //    with a 4096×3072 RGBA source (~50 MB) + ORT's
      //    intermediate feature maps for a 1024² matter, peak
      //    memory blew past the iOS ceiling.
      //
      //    2048 long edge halves the source RGBA (~13 MB) and
      //    still preserves significantly more interior detail
      //    than the 1024 default — the BiRefNet matte's
      //    transition band caps at 1024² regardless, so going
      //    above 2048 only helps tiny pinch-zoom margins that
      //    the iOS app-memory budget can't accommodate today.
      final decoded = await BgRemovalImageIo.decodeFileToRgba(
        sourcePath,
        maxDimension: BgRemovalImageIo.previewQualityDecodeDimension,
      );
      _log.d('source decoded', {
        'path': sourcePath,
        'w': decoded.width,
        'h': decoded.height,
      });

      // 2. Build the input tensor — BiRefNet uses ImageNet
      //    normalisation, unlike RMBG (plain [0, 1]).
      final preSw = Stopwatch()..start();
      final tensor = ImageTensor.fromRgba(
        rgba: decoded.bytes,
        srcWidth: decoded.width,
        srcHeight: decoded.height,
        dstWidth: inputSize,
        dstHeight: inputSize,
        mean: const [0.485, 0.456, 0.406],
        std: const [0.229, 0.224, 0.225],
      );
      preSw.stop();
      _log.d('preprocessed', {'ms': preSw.elapsedMilliseconds});

      // 3. Wrap input + run inference. Common BiRefNet ONNX exports
      //    use 'input_image' or 'pixel_values' — the picker tolerates
      //    either; falls back to the first declared name.
      final inputName = pickInputName(session.inputNames);
      if (inputName == null) {
        throw const BgRemovalException(
          'BiRefNet session has no named inputs',
          kind: BgRemovalStrategyKind.birefnetLite,
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
        throw const BgRemovalException(
          'BiRefNet returned no output tensor',
          kind: BgRemovalStrategyKind.birefnetLite,
        );
      }

      // 4. Extract the alpha mask. The onnx-community BiRefNet
      //    export does NOT bake sigmoid into the graph — the output
      //    is raw logits. Apply sigmoid here so downstream code
      //    sees a [0, 1] alpha map. (Some community exports emit a
      //    list of multi-scale outputs from deep supervision; we
      //    take the first which is the finest-resolution
      //    prediction.) Cross-checked against the transformers.js
      //    reference snippet on the model card which does
      //    `output_image[0].sigmoid().mul(255).to('uint8')`.
      final raw = outputs.first!.value;
      final mask = flattenMask(raw);
      if (mask == null) {
        throw const BgRemovalException(
          'BiRefNet output shape unrecognised — expected [1,1,H,W]',
          kind: BgRemovalStrategyKind.birefnetLite,
        );
      }
      sigmoidInPlace(mask);
      final stats = MaskStats.compute(mask);
      _log.d('mask stats', stats.toLogMap());
      if (stats.isEffectivelyEmpty) {
        _log.w('mask is effectively empty', stats.toLogMap());
      } else if (stats.isEffectivelyFull) {
        _log.w(
            'mask is effectively full (subject covers whole image?)',
            stats.toLogMap());
      }

      // 5. Blend mask into the native-resolution source. The helper
      //    bilinear-upsamples the mask to the source dims internally.
      final postSw = Stopwatch()..start();
      var rgba = blendMaskIntoRgba(
        mask: mask,
        maskWidth: inputSize,
        maskHeight: inputSize,
        sourceRgba: decoded.bytes,
        srcWidth: decoded.width,
        srcHeight: decoded.height,
      );

      // 6. Edge refine with upscale-scaled decontam (mirrors the
      //    XVI.66c.fix RMBG path). For a 1024-mask upsampled to a
      //    4096 source = 4× upscale = radius-8 kernel.
      final upscale = (decoded.width / inputSize)
          .clamp(1.0, 8.0);
      final decontamRadius = (2 * upscale).round().clamp(2, 16);
      _log.d('edge refine config', {
        'srcW': decoded.width,
        'srcH': decoded.height,
        'matteSize': inputSize,
        'upscale': upscale.toStringAsFixed(2),
        'decontamRadius': decontamRadius,
        'featherPx': edgeFeatherPx,
      });
      rgba = ComposeEdgeRefine.apply(
        straightRgba: rgba,
        width: decoded.width,
        height: decoded.height,
        featherPx: edgeFeatherPx,
        decontamRadius: decontamRadius,
      );
      postSw.stop();
      _log.d('postprocessed', {'ms': postSw.elapsedMilliseconds});

      // 7. Encode the cutout.
      final cutout = await BgRemovalImageIo.encodeRgbaToUiImage(
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
        'outputW': cutout.width,
        'outputH': cutout.height,
      });
      return cutout;
    } on BgRemovalException {
      rethrow;
    } on BgRemovalIoException catch (e) {
      _log.w('run IO failure — rewrapping', {'message': e.message});
      throw BgRemovalException(
        e.message,
        kind: BgRemovalStrategyKind.birefnetLite,
        cause: e,
      );
    } catch (e, st) {
      total.stop();
      _log.e('run failed',
          error: e,
          stackTrace: st,
          data: {'ms': total.elapsedMilliseconds});
      throw BgRemovalException(
        e.toString(),
        kind: BgRemovalStrategyKind.birefnetLite,
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

  /// Pick the most likely input name from the session's declared
  /// inputs. BiRefNet ONNX exports vary: HuggingFace `transformers`
  /// pipeline exports use `'pixel_values'`; the official torch
  /// export uses `'input_image'`; some quantised variants use
  /// `'input'`. Falls back to the first declared name when nothing
  /// matches.
  @visibleForTesting
  static String? pickInputName(List<String> names) {
    const candidates = ['input_image', 'pixel_values', 'input', 'image'];
    for (final c in candidates) {
      for (final n in names) {
        final lower = n.toLowerCase();
        if (lower == c || lower.endsWith(c)) return n;
      }
    }
    return names.isEmpty ? null : names.first;
  }

  /// Apply sigmoid in-place to a logit tensor: `1 / (1 + exp(-x))`.
  /// Mirrors the `output_image.sigmoid()` step in the
  /// transformers.js reference snippet on the BiRefNet model card —
  /// the onnx-community export emits raw logits because the
  /// upstream PyTorch model's sigmoid lives in the loss function,
  /// not the forward pass.
  @visibleForTesting
  static void sigmoidInPlace(Float32List logits) {
    for (var i = 0; i < logits.length; i++) {
      final x = logits[i];
      // Numerically stable sigmoid — saturate the extremes so
      // exp(-x) doesn't overflow on large negative inputs.
      if (x >= 0) {
        final z = math.exp(-x);
        logits[i] = 1.0 / (1.0 + z);
      } else {
        final z = math.exp(x);
        logits[i] = z / (1.0 + z);
      }
    }
  }

  /// Walk a `[1, 1, H, W]` (or `[1, H, W]` or `[H, W]`) raw-logit
  /// output tensor into a flat `Float32List`. Returns null when
  /// the shape doesn't match. Mirrors RMBG's `_flattenMask` —
  /// kept separate so the variants can diverge per-architecture
  /// without stepping on each other. Caller applies
  /// [sigmoidInPlace] before consuming.
  @visibleForTesting
  static Float32List? flattenMask(Object? raw) {
    if (raw is! List || raw.isEmpty) return null;
    List current = raw;
    // Strip leading batch dim if present.
    if (current.first is List &&
        (current.first as List).isNotEmpty &&
        (current.first as List).first is List) {
      // Either [1, 1, H, W] (4-D) or [1, H, W] (3-D); peel until
      // we land on the [H, W] inner.
      while (current.length == 1 &&
          current.first is List &&
          (current.first as List).isNotEmpty &&
          (current.first as List).first is List) {
        current = current.first as List;
      }
    }
    if (current.isEmpty || current.first is! List) return null;
    final height = current.length;
    final firstRow = current.first as List;
    final width = firstRow.length;
    if (width == 0) return null;
    final out = Float32List(height * width);
    for (var y = 0; y < height; y++) {
      final row = current[y];
      if (row is! List || row.length != width) return null;
      for (var x = 0; x < width; x++) {
        final v = row[x];
        if (v is num) {
          out[y * width + x] = v.toDouble();
        } else {
          return null;
        }
      }
    }
    return out;
  }
}

/// Stable model id for the downloaded BiRefNet_lite ONNX (Zheng
/// 2024). Used by the AI bootstrap's `ModelRegistry.resolve()`
/// call. The HR / portrait / full variants can be swapped in by
/// updating the manifest pin and (optionally) the
/// [BiRefNetBgRemoval.inputSize] constructor argument — no code
/// change required.
const String kBiRefNetLiteModelId = 'birefnet_lite_fp32';
