import 'dart:math' as math;
import 'dart:typed_data';

import 'package:onnxruntime_v2/onnxruntime_v2.dart' as ort;

import '../../../core/logging/app_logger.dart';
import '../../runtime/ort_runtime.dart';
import '../bg_removal/image_io.dart';

final _log = AppLogger('MobileSamSegmenter');

/// Phase XVI.78b — MobileSAM tap-to-segment service.
///
/// MobileSAM (Zhang et al. 2023, github.com/ChaoningZhang/MobileSAM)
/// is a distilled Segment Anything Model with a ViT-Tiny image
/// encoder (~28 MB) and the same lightweight mask decoder as the
/// original SAM. Two-stage interactive segmentation:
///
///   1. **Encoder** runs ONCE per image: decoded source → fp32
///      `[1, 256, 64, 64]` embedding. Cached so the per-tap cost is
///      just the decoder.
///   2. **Decoder** runs PER TAP: embedding + point prompt(s) → an
///      `[H, W]` alpha mask aligned to the encoded source. Latency
///      is dominated by the encoder (~200 ms), so subsequent taps
///      on the same image return in ~30 ms.
///
/// The Acly export this service targets has two unusual properties:
///   * Encoder input is HWC fp32 (not BCHW) with DYNAMIC spatial
///     dims — feeds the source at its decoded resolution rather
///     than a fixed 1024×1024. The encoder normalises with the
///     standard SAM mean/std (`[123.675, 116.28, 103.53]` /
///     `[58.395, 57.12, 57.375]`) INTERNALLY, so the caller passes
///     raw `[0, 255]` RGB.
///   * Decoder requires six inputs (the standard SAM contract).
///     `point_coords` are in the **decoded** image's coordinate
///     space; the UI layer is responsible for mapping editor-canvas
///     taps into decoded coords before calling here.
///
/// Output mask values are RAW LOGITS — the decoder does not bake
/// sigmoid in. [_decode] thresholds at `> 0` (equivalent to
/// `sigmoid > 0.5`) to produce a binary alpha mask.
///
/// ## Lifecycle
///
/// One instance per editor session. Encoder + decoder sessions are
/// disposed together via [close]. The embedding cache is invalidated
/// when [segmentAt] / [prepareImage] is called with a different
/// source path.
class MobileSamSegmenter {
  MobileSamSegmenter({
    required this.encoderSession,
    required this.decoderSession,
    this.encoderInputMaxDim = kDefaultEncoderInputMaxDim,
  });

  /// Max long-edge dimension we'll decode the source to before
  /// feeding the encoder. SAM was trained at 1024; going above
  /// wastes encoder memory without improving mask quality (the
  /// decoder's mask resolution is bounded by the embedding's
  /// 64×64 spatial dim ÷ patch-size anyway).
  static const int kDefaultEncoderInputMaxDim = 1024;

  /// Same model id used by the manifest entry.
  static const String kEncoderModelId = 'mobile_sam_encoder';
  static const String kDecoderModelId = 'mobile_sam_decoder';

  final OrtV2Session encoderSession;
  final OrtV2Session decoderSession;
  final int encoderInputMaxDim;

  /// Last successfully-computed encoder embedding. Keyed by source
  /// path so repeated taps on the same image short-circuit. Goes
  /// stale silently when the path changes — that's fine, the
  /// embedding is cheap to discard.
  MobileSamEmbedding? _cached;
  bool _closed = false;

  /// Warm the encoder cache for [sourcePath] without producing a
  /// mask. Useful when the UI knows the user is about to start
  /// tapping (e.g. when they enter Remove Object's tap mode) — we
  /// pay the ~200 ms encoder cost during the affordance animation
  /// rather than on the first tap.
  Future<void> prepareImage(String sourcePath) async {
    if (_closed) {
      throw const MobileSamException(
          'MobileSamSegmenter is closed; cannot prepare image');
    }
    await _encodeIfNeeded(sourcePath);
  }

  /// Run a single-point foreground segmentation at [x], [y].
  ///
  /// [x] / [y] are in the source image's pixel coordinate space
  /// (origin top-left, x = column, y = row). For multi-point or
  /// background-point prompts, use [segmentAtPoints] directly.
  Future<MobileSamMask> segmentAt({
    required String sourcePath,
    required double x,
    required double y,
  }) =>
      segmentAtPoints(
        sourcePath: sourcePath,
        points: [MobileSamPoint(x: x, y: y, foreground: true)],
      );

  /// Run segmentation with N point prompts. Each point can be
  /// foreground (mark the subject) or background (mark the
  /// surroundings) — the decoder fuses them into a single mask.
  ///
  /// Passing 1+ points is mandatory; SAM cannot segment "anything"
  /// from an embedding alone. The caller can also pass a
  /// [priorLowResMask] from a previous call to refine the mask
  /// click-by-click; pass `null` for the first tap.
  Future<MobileSamMask> segmentAtPoints({
    required String sourcePath,
    required List<MobileSamPoint> points,
    Float32List? priorLowResMask,
  }) async {
    if (_closed) {
      throw const MobileSamException(
          'MobileSamSegmenter is closed; cannot segment');
    }
    if (points.isEmpty) {
      throw const MobileSamException(
          'segmentAtPoints requires at least one point');
    }
    final embedding = await _encodeIfNeeded(sourcePath);
    return _decode(
      embedding: embedding,
      points: points,
      priorLowResMask: priorLowResMask,
    );
  }

  Future<MobileSamEmbedding> _encodeIfNeeded(String sourcePath) async {
    final hit = _cached;
    if (hit != null && hit.sourcePath == sourcePath) {
      _log.d('encode cache hit', {'path': sourcePath});
      return hit;
    }
    return _encode(sourcePath);
  }

  Future<MobileSamEmbedding> _encode(String sourcePath) async {
    final total = Stopwatch()..start();
    _log.i('encode start', {
      'path': sourcePath,
      'inputs': encoderSession.inputNames,
      'outputs': encoderSession.outputNames,
      'maxDim': encoderInputMaxDim,
    });

    ort.OrtValue? inputValue;
    List<ort.OrtValue?>? outputs;
    try {
      // 1. Decode the source. The Acly encoder accepts dynamic HWC
      //    but ViT-Tiny was distilled from SAM at 1024 long edge —
      //    larger inputs waste memory without improving the
      //    64×64 spatial-token grid the decoder reads.
      final decoded = await BgRemovalImageIo.decodeFileToRgba(
        sourcePath,
        maxDimension: encoderInputMaxDim,
      );
      _log.d('source decoded', {
        'path': sourcePath,
        'w': decoded.width,
        'h': decoded.height,
      });

      // 2. Build HWC fp32 in [0, 255] (the encoder normalises
      //    internally — see header doc). We drop the alpha channel
      //    while transcribing.
      final preSw = Stopwatch()..start();
      final hwc = _buildHwcRgbTensor(decoded.bytes, decoded.width,
          decoded.height);
      preSw.stop();
      _log.d('preprocessed', {'ms': preSw.elapsedMilliseconds});

      // 3. Wrap as an OrtValue + run.
      final inputName = encoderSession.inputNames.isEmpty
          ? null
          : encoderSession.inputNames.first;
      if (inputName == null) {
        throw const MobileSamException(
            'Encoder session has no named inputs');
      }
      inputValue = ort.OrtValueTensor.createTensorWithDataList(
        hwc,
        [decoded.height, decoded.width, 3],
      );
      final inferSw = Stopwatch()..start();
      outputs = await encoderSession.runTyped({inputName: inputValue});
      inferSw.stop();
      _log.d('encoder ran', {'ms': inferSw.elapsedMilliseconds});

      if (outputs.isEmpty || outputs.first == null) {
        throw const MobileSamException(
            'Encoder returned no output tensor');
      }
      final raw = outputs.first!.value;
      final flat = _flattenFloat32(raw);
      if (flat == null) {
        throw const MobileSamException(
            'Encoder output shape unrecognised — expected [1,256,64,64]');
      }
      if (flat.length != 1 * 256 * 64 * 64) {
        throw MobileSamException(
            'Encoder output length ${flat.length} ≠ expected ${1 * 256 * 64 * 64}');
      }

      final embedding = MobileSamEmbedding(
        sourcePath: sourcePath,
        decodedWidth: decoded.width,
        decodedHeight: decoded.height,
        data: flat,
      );
      _cached = embedding;
      total.stop();
      _log.i('encode complete', {
        'totalMs': total.elapsedMilliseconds,
        'preMs': preSw.elapsedMilliseconds,
        'inferMs': inferSw.elapsedMilliseconds,
        'decodedW': decoded.width,
        'decodedH': decoded.height,
      });
      return embedding;
    } on MobileSamException {
      rethrow;
    } on BgRemovalIoException catch (e) {
      _log.w('encode IO failure — rewrapping', {'message': e.message});
      throw MobileSamException(e.message, cause: e);
    } catch (e, st) {
      total.stop();
      _log.e('encode failed',
          error: e,
          stackTrace: st,
          data: {'ms': total.elapsedMilliseconds});
      throw MobileSamException(e.toString(), cause: e);
    } finally {
      try {
        inputValue?.release();
      } catch (e) {
        _log.w('encoder input release failed', {'error': e.toString()});
      }
      if (outputs != null) {
        for (final o in outputs) {
          try {
            o?.release();
          } catch (e) {
            _log.w('encoder output release failed', {'error': e.toString()});
          }
        }
      }
    }
  }

  Future<MobileSamMask> _decode({
    required MobileSamEmbedding embedding,
    required List<MobileSamPoint> points,
    Float32List? priorLowResMask,
  }) async {
    final total = Stopwatch()..start();
    _log.i('decode start', {
      'sourcePath': embedding.sourcePath,
      'points': points.length,
      'priorMask': priorLowResMask != null,
    });

    // Build the six standard SAM decoder inputs. The Acly decoder
    // uses the exact same I/O contract as the official SAM decoder,
    // so any cookbook works.
    final coords = Float32List(points.length * 2);
    final labels = Float32List(points.length);
    for (var i = 0; i < points.length; i++) {
      coords[i * 2] = points[i].x;
      coords[i * 2 + 1] = points[i].y;
      labels[i] = points[i].foreground ? 1.0 : 0.0;
    }
    final maskInput = priorLowResMask ?? Float32List(1 * 1 * 256 * 256);
    final hasMaskInput = Float32List.fromList([priorLowResMask != null ? 1.0 : 0.0]);
    final origSize = Float32List.fromList(
      [embedding.decodedHeight.toDouble(), embedding.decodedWidth.toDouble()],
    );

    final inputs = <String, ort.OrtValue>{};
    final toRelease = <ort.OrtValue>[];
    List<ort.OrtValue?>? outputs;
    try {
      inputs['image_embeddings'] = ort.OrtValueTensor.createTensorWithDataList(
        embedding.data,
        [1, 256, 64, 64],
      );
      inputs['point_coords'] = ort.OrtValueTensor.createTensorWithDataList(
        coords,
        [1, points.length, 2],
      );
      inputs['point_labels'] = ort.OrtValueTensor.createTensorWithDataList(
        labels,
        [1, points.length],
      );
      inputs['mask_input'] = ort.OrtValueTensor.createTensorWithDataList(
        maskInput,
        [1, 1, 256, 256],
      );
      inputs['has_mask_input'] = ort.OrtValueTensor.createTensorWithDataList(
        hasMaskInput,
        [1],
      );
      inputs['orig_im_size'] = ort.OrtValueTensor.createTensorWithDataList(
        origSize,
        [2],
      );
      toRelease.addAll(inputs.values);

      final inferSw = Stopwatch()..start();
      outputs = await decoderSession.runTyped(inputs);
      inferSw.stop();
      _log.d('decoder ran', {'ms': inferSw.elapsedMilliseconds});

      if (outputs.length < 2 || outputs[0] == null || outputs[1] == null) {
        throw const MobileSamException(
            'Decoder must return masks + iou_predictions');
      }

      // masks is [1, 1, H, W] resized to orig_im_size; we threshold
      // at 0 to get a binary mask (sigmoid(0) = 0.5).
      final masksRaw = _flattenFloat32(outputs[0]!.value);
      if (masksRaw == null) {
        throw const MobileSamException(
            'Decoder masks output shape unrecognised');
      }
      final expectedLen = embedding.decodedWidth * embedding.decodedHeight;
      if (masksRaw.length != expectedLen) {
        throw MobileSamException(
            'Decoder masks length ${masksRaw.length} ≠ expected $expectedLen '
            '(${embedding.decodedWidth}×${embedding.decodedHeight})');
      }
      final alpha = Uint8List(expectedLen);
      var fgCount = 0;
      for (var i = 0; i < expectedLen; i++) {
        if (masksRaw[i] > 0.0) {
          alpha[i] = 255;
          fgCount++;
        }
      }

      // iou_predictions is [1, 1] (single-mask variant).
      final iouRaw = _flattenFloat32(outputs[1]!.value);
      final iou = (iouRaw != null && iouRaw.isNotEmpty) ? iouRaw[0] : 0.0;

      // low_res_masks [1, 1, 256, 256] — surface for click-refinement.
      Float32List? lowRes;
      if (outputs.length >= 3 && outputs[2] != null) {
        lowRes = _flattenFloat32(outputs[2]!.value);
      }

      total.stop();
      final fgRatio = fgCount / expectedLen;
      _log.i('decode complete', {
        'totalMs': total.elapsedMilliseconds,
        'inferMs': inferSw.elapsedMilliseconds,
        'maskW': embedding.decodedWidth,
        'maskH': embedding.decodedHeight,
        'iou': iou.toStringAsFixed(3),
        'foregroundRatio': fgRatio.toStringAsFixed(3),
      });
      if (fgRatio < 0.001) {
        _log.w('mask is effectively empty', {'fgRatio': fgRatio});
      } else if (fgRatio > 0.95) {
        _log.w('mask covers nearly the whole image — '
            'tap may have hit a low-confidence region',
            {'fgRatio': fgRatio});
      }

      return MobileSamMask(
        alpha: alpha,
        width: embedding.decodedWidth,
        height: embedding.decodedHeight,
        iou: iou,
        lowResLogits: lowRes,
      );
    } on MobileSamException {
      rethrow;
    } catch (e, st) {
      total.stop();
      _log.e('decode failed',
          error: e,
          stackTrace: st,
          data: {'ms': total.elapsedMilliseconds});
      throw MobileSamException(e.toString(), cause: e);
    } finally {
      for (final v in toRelease) {
        try {
          v.release();
        } catch (e) {
          _log.w('decoder input release failed', {'error': e.toString()});
        }
      }
      if (outputs != null) {
        for (final o in outputs) {
          try {
            o?.release();
          } catch (e) {
            _log.w('decoder output release failed', {'error': e.toString()});
          }
        }
      }
    }
  }

  /// Drop the embedding cache. Useful when the user dismisses the
  /// segmentation UI and the next session may target a different
  /// image — calling [segmentAt] would discard it anyway but this
  /// frees the ~1 MB embedding buffer earlier.
  void clearCache() {
    _cached = null;
    _log.d('cache cleared');
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _cached = null;
    _log.i('close');
    await encoderSession.close();
    await decoderSession.close();
  }

  /// Build a flat HWC Float32 buffer from an RGBA byte buffer. The
  /// Acly MobileSAM encoder expects raw `[0, 255]` RGB values; no
  /// `/ 255` step and no mean/std subtraction here.
  static Float32List _buildHwcRgbTensor(
    Uint8List rgba,
    int width,
    int height,
  ) {
    final hwc = Float32List(height * width * 3);
    for (var p = 0, src = 0, dst = 0;
        p < height * width;
        p++, src += 4, dst += 3) {
      hwc[dst] = rgba[src].toDouble();
      hwc[dst + 1] = rgba[src + 1].toDouble();
      hwc[dst + 2] = rgba[src + 2].toDouble();
    }
    return hwc;
  }

  /// Flatten an arbitrary nested-list tensor returned by ORT into a
  /// single Float32List. Matches the BiRefNet/RMBG pattern. Handles
  /// the three nesting depths we expect from MobileSAM outputs:
  /// `[1, 256, 64, 64]` (embedding, depth 4), `[1, 1, H, W]` (mask,
  /// depth 4), `[1, 1]` (iou, depth 2).
  static Float32List? _flattenFloat32(Object? value) {
    if (value == null) return null;
    if (value is Float32List) return value;
    if (value is List) {
      final flat = <double>[];
      _walk(value, flat);
      return Float32List.fromList(flat);
    }
    return null;
  }

  static void _walk(List<dynamic> list, List<double> out) {
    for (final v in list) {
      if (v is num) {
        out.add(v.toDouble());
      } else if (v is List) {
        _walk(v, out);
      }
    }
  }
}

/// Result of [MobileSamSegmenter.segmentAt*]. The alpha mask is
/// aligned to the decoded source image (the same dimensions the
/// encoder consumed); the UI layer maps it back to canvas
/// coordinates when blending.
class MobileSamMask {
  const MobileSamMask({
    required this.alpha,
    required this.width,
    required this.height,
    required this.iou,
    this.lowResLogits,
  });

  /// Binary alpha mask: `255` = subject, `0` = background. Length is
  /// `width * height`.
  final Uint8List alpha;

  final int width;
  final int height;

  /// Decoder-reported intersection-over-union confidence in `[0, 1]`.
  /// Below ~0.7 usually means the tap landed on an ambiguous region
  /// (object boundary, background texture); the UI can show a hint.
  final double iou;

  /// `[1, 1, 256, 256]` low-resolution mask logits. Pass back to
  /// [MobileSamSegmenter.segmentAtPoints] as `priorLowResMask` to
  /// refine the mask click-by-click — SAM was trained for this
  /// workflow and the second/third clicks usually nail edges that
  /// the first click missed.
  final Float32List? lowResLogits;

  /// Approximate count of foreground pixels — convenience for
  /// "did this tap segment anything visible?" guards in the UI.
  int get foregroundPixelCount {
    var n = 0;
    for (var i = 0; i < alpha.length; i++) {
      if (alpha[i] > 0) n++;
    }
    return n;
  }

  /// Foreground area as a fraction of the mask area in `[0, 1]`.
  double get foregroundRatio =>
      alpha.isEmpty ? 0.0 : foregroundPixelCount / alpha.length;
}

/// A single point prompt for [MobileSamSegmenter.segmentAtPoints].
class MobileSamPoint {
  const MobileSamPoint({
    required this.x,
    required this.y,
    required this.foreground,
  });

  /// Pixel x in the **decoded source** image's coordinate space.
  final double x;

  /// Pixel y in the **decoded source** image's coordinate space.
  final double y;

  /// `true` = include in subject (positive prompt), `false` =
  /// exclude (negative prompt). SAM fuses positive + negative
  /// prompts; mixing them is the recommended way to remove a
  /// distractor that the first click accidentally pulled in.
  final bool foreground;

  /// Convert canvas-space `(canvasX, canvasY)` to decoded-source-
  /// space by scaling. Convenience for the UI layer.
  static MobileSamPoint fromCanvas({
    required double canvasX,
    required double canvasY,
    required double canvasWidth,
    required double canvasHeight,
    required int decodedWidth,
    required int decodedHeight,
    required bool foreground,
  }) {
    final scaleX = decodedWidth / math.max(canvasWidth, 1.0);
    final scaleY = decodedHeight / math.max(canvasHeight, 1.0);
    return MobileSamPoint(
      x: canvasX * scaleX,
      y: canvasY * scaleY,
      foreground: foreground,
    );
  }
}

/// Cached encoder output. Survives across decoder calls within the
/// same image; invalidated automatically when the next encode runs
/// against a different source path.
class MobileSamEmbedding {
  const MobileSamEmbedding({
    required this.sourcePath,
    required this.decodedWidth,
    required this.decodedHeight,
    required this.data,
  });

  final String sourcePath;
  final int decodedWidth;
  final int decodedHeight;

  /// Flat `[1 * 256 * 64 * 64]` embedding buffer.
  final Float32List data;
}

/// Typed exception for MobileSAM failures. Carries the underlying
/// cause when wrapping an `MlRuntimeException` / `BgRemovalIoException`
/// so the editor's logs keep the full failure chain.
class MobileSamException implements Exception {
  const MobileSamException(this.message, {this.cause});

  final String message;
  final Object? cause;

  @override
  String toString() {
    final suffix = cause == null ? '' : ' (caused by $cause)';
    return 'MobileSamException: $message$suffix';
  }
}
