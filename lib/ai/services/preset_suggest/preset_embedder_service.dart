import 'dart:typed_data';
import 'dart:math' as math;

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:onnxruntime_v2/onnxruntime_v2.dart' as ort;

import '../../../core/logging/app_logger.dart';
import '../../inference/image_tensor.dart';
import '../../runtime/ort_runtime.dart';
import '../bg_removal/image_io.dart';

final _log = AppLogger('PresetEmbedderService');

/// Phase XVI.58 — preset-suggestion embedding service.
///
/// The audit plan called for MobileViT v2 (~30 MB) embedding the
/// source proxy + KNN against pre-baked preset embeddings to drive
/// a "For You" rail in the preset strip. Per the user's XVI.58
/// selection we ship the smallest variant: MobileViT-v2-0.5 INT8
/// (~7 MB), which is plenty for similarity retrieval.
///
/// ## I/O contract
///
/// **Input:** `[1, 3, inputSize, inputSize]` float32, ImageNet-
/// normalised (mean=[0.485,0.456,0.406], std=[0.229,0.224,0.225]).
/// inputSize defaults to 256 — MobileViT-v2's native training size.
///
/// **Output:** `[1, embeddingDim]` float32 — the network's pooled
/// feature vector. The exact dim is encoder-dependent (typically
/// 256 or 384 for MobileViT-v2-0.5); we treat it as opaque and
/// just L2-normalise before exposing.
///
/// ## Pipeline
///
/// 1. Decode source to RGBA (capped at 1024 px on long edge).
/// 2. Build CHW tensor at inputSize × inputSize, ImageNet-normalised.
/// 3. Single ORT inference call.
/// 4. Flatten output to a 1-D Float32List.
/// 5. L2-normalise so cosine similarity collapses to a dot product
///    when callers compare it against a library of pre-baked
///    embeddings.
///
/// Silent fallback per project convention.
class PresetEmbedderService {
  PresetEmbedderService({
    required this.session,
    this.inputSize = 256,
  });

  final OrtV2Session session;
  final int inputSize;
  bool _closed = false;

  /// Embed the source image at [sourcePath]. Returns an L2-normalised
  /// Float32 vector suitable for cosine-similarity retrieval against
  /// a pre-baked preset library.
  Future<Float32List> embedFromPath(String sourcePath) async {
    if (_closed) {
      _log.w('run rejected — session closed', {'path': sourcePath});
      throw const PresetEmbedderException('PresetEmbedderService is closed');
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
      // 1. Decode source.
      final decoded = await BgRemovalImageIo.decodeFileToRgba(sourcePath);
      _log.d('source decoded', {'w': decoded.width, 'h': decoded.height});

      // 2. ImageNet-normalised CHW tensor.
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

      // 3. Inference.
      final inputName = pickInputName(session.inputNames);
      if (inputName == null) {
        throw PresetEmbedderException(
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

      if (outputs.isEmpty || outputs.first == null) {
        throw const PresetEmbedderException(
          'Embedder returned no output tensor',
        );
      }
      // 4. Flatten.
      final embedding = flattenEmbedding(outputs.first!.value);
      if (embedding == null || embedding.isEmpty) {
        throw const PresetEmbedderException(
          'Embedder output shape unrecognised — expected [1, D] or [D]',
        );
      }
      // 5. L2-normalise.
      final normalised = l2Normalise(embedding);
      total.stop();
      _log.i('run complete', {
        'totalMs': total.elapsedMilliseconds,
        'preMs': preSw.elapsedMilliseconds,
        'inferMs': inferSw.elapsedMilliseconds,
        'dim': normalised.length,
      });
      return normalised;
    } on PresetEmbedderException {
      rethrow;
    } on BgRemovalIoException catch (e) {
      _log.w('run IO failure — rewrapping', {'message': e.message});
      throw PresetEmbedderException(e.message, cause: e);
    } catch (e, st) {
      total.stop();
      _log.e('run failed',
          error: e, stackTrace: st, data: {'ms': total.elapsedMilliseconds});
      throw PresetEmbedderException(e.toString(), cause: e);
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
  /// vision-encoder naming conventions ('input', 'pixel_values',
  /// 'image', 'sample'). Falls back to the first declared name when
  /// no candidate matches.
  @visibleForTesting
  static String? pickInputName(List<String> names) {
    const candidates = ['input', 'pixel_values', 'image', 'sample'];
    for (final c in candidates) {
      for (final n in names) {
        final lower = n.toLowerCase();
        if (lower == c || lower.endsWith(c)) return n;
      }
    }
    return names.isEmpty ? null : names.first;
  }

  /// Walk a `[1, D]` or `[D]` embedding tensor into a flat
  /// Float32List. Returns null when the shape doesn't match.
  @visibleForTesting
  static Float32List? flattenEmbedding(Object? raw) {
    if (raw is! List || raw.isEmpty) return null;
    List current = raw;
    // Drop leading batch dim if present.
    if (current.first is List) {
      current = current.first as List;
    }
    final out = Float32List(current.length);
    for (var i = 0; i < current.length; i++) {
      final v = current[i];
      if (v is num) {
        out[i] = v.toDouble();
      } else {
        return null;
      }
    }
    return out;
  }

  /// L2-normalise a vector in place — divide every component by the
  /// vector's L2 norm. Returns the same Float32List for chaining.
  /// Zero-magnitude vectors are returned unchanged (avoids div-by-0).
  @visibleForTesting
  static Float32List l2Normalise(Float32List v) {
    var sumSq = 0.0;
    for (var i = 0; i < v.length; i++) {
      sumSq += v[i] * v[i];
    }
    if (sumSq <= 0) return v;
    final inv = 1.0 / math.sqrt(sumSq);
    for (var i = 0; i < v.length; i++) {
      v[i] *= inv;
    }
    return v;
  }
}

/// Stable model id for the downloaded MobileViT-v2-0.5 INT8 ONNX.
const String kPresetEmbedderModelId = 'mobilevit_v2_0_5_int8';

class PresetEmbedderException implements Exception {
  const PresetEmbedderException(this.message, {this.cause});
  final String message;
  final Object? cause;

  @override
  String toString() {
    if (cause == null) return 'PresetEmbedderException: $message';
    return 'PresetEmbedderException: $message (caused by $cause)';
  }
}
