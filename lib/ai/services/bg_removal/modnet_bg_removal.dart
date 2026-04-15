import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:onnxruntime_v2/onnxruntime_v2.dart' as ort;

import '../../../core/logging/app_logger.dart';
import '../../inference/image_tensor.dart';
import '../../inference/mask_stats.dart';
import '../../inference/mask_to_alpha.dart';
import '../../runtime/ort_runtime.dart';
import 'bg_removal_strategy.dart';
import 'image_io.dart';

final _log = AppLogger('ModNetBgRemoval');

/// Background removal via MODNet (downloaded ONNX model).
///
/// MODNet is a portrait-matting network that outputs a soft alpha
/// matte with noticeably better hair / edge detail than MediaPipe.
/// Input: `[1, 3, 512, 512]` float32 in `[-1, 1]`
/// Output: `[1, 1, 512, 512]` float32 in `[0, 1]`
///
/// The strategy owns an [OrtV2Session] for its lifetime; callers
/// should reuse the instance across multiple `removeBackgroundFromPath`
/// calls to avoid reloading the model. On [close], the session
/// is released.
class ModNetBgRemoval implements BgRemovalStrategy {
  ModNetBgRemoval({required this.session});

  /// Expected spatial resolution for MODNet's input tensor.
  static const int inputSize = 512;

  /// Per-channel normalization: maps `[0, 1]` pixels to `[-1, 1]`.
  static const List<double> _mean = [0.5, 0.5, 0.5];
  static const List<double> _std = [0.5, 0.5, 0.5];

  final OrtV2Session session;
  bool _closed = false;

  @override
  BgRemovalStrategyKind get kind => BgRemovalStrategyKind.modnet;

  @override
  Future<ui.Image> removeBackgroundFromPath(String sourcePath) async {
    if (_closed) {
      _log.w('run rejected — session closed', {'path': sourcePath});
      throw const BgRemovalException(
        'ModNetBgRemoval is closed',
        kind: BgRemovalStrategyKind.modnet,
      );
    }
    final total = Stopwatch()..start();
    _log.i('run start', {'path': sourcePath});
    ort.OrtValue? inputValue;
    List<ort.OrtValue?>? outputs;
    try {
      // 1. Decode source image into raw RGBA.
      final decoded = await BgRemovalImageIo.decodeFileToRgba(sourcePath);
      _log.d('source decoded', {
        'path': sourcePath,
        'w': decoded.width,
        'h': decoded.height,
      });

      // 2. Build the input tensor (bilinear resize + normalize).
      final preSw = Stopwatch()..start();
      final tensor = ImageTensor.fromRgba(
        rgba: decoded.bytes,
        srcWidth: decoded.width,
        srcHeight: decoded.height,
        dstWidth: inputSize,
        dstHeight: inputSize,
        mean: _mean,
        std: _std,
      );
      preSw.stop();
      _log.d('preprocessed', {'ms': preSw.elapsedMilliseconds});

      // 3. Wrap in an OrtValueTensor and run inference.
      if (session.inputNames.isEmpty) {
        throw const BgRemovalException(
          'MODNet session has no named inputs — model metadata is corrupt',
          kind: BgRemovalStrategyKind.modnet,
        );
      }
      final inputName = session.inputNames.first;
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
          'MODNet returned no output tensor',
          kind: BgRemovalStrategyKind.modnet,
        );
      }

      // 4. Extract the float mask.
      final raw = outputs.first!.value;
      final mask = _flattenMask(raw);
      if (mask == null) {
        throw const BgRemovalException(
          'MODNet output shape unrecognized',
          kind: BgRemovalStrategyKind.modnet,
        );
      }

      final stats = MaskStats.compute(mask);
      _log.d('mask stats', stats.toLogMap());
      if (stats.isEffectivelyEmpty) {
        _log.w('mask is effectively empty', stats.toLogMap());
      } else if (stats.isEffectivelyFull) {
        _log.w('mask is effectively full (subject covers whole image?)',
            stats.toLogMap());
      }

      // 5. Blend the mask into the source image's alpha channel.
      final postSw = Stopwatch()..start();
      final rgba = blendMaskIntoRgba(
        mask: mask,
        maskWidth: inputSize,
        maskHeight: inputSize,
        sourceRgba: decoded.bytes,
        srcWidth: decoded.width,
        srcHeight: decoded.height,
      );
      postSw.stop();

      // 6. Re-upload as a ui.Image.
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
        kind: BgRemovalStrategyKind.modnet,
      );
    } catch (e, st) {
      total.stop();
      _log.e('run failed',
          error: e, stackTrace: st, data: {'ms': total.elapsedMilliseconds});
      throw BgRemovalException(
        e.toString(),
        kind: BgRemovalStrategyKind.modnet,
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

  /// Walk a nested `[1][1][H][W]` list-of-doubles tensor into a flat
  /// [Float32List]. Returns null if the shape doesn't match.
  static Float32List? _flattenMask(Object? raw) {
    if (raw is! List || raw.isEmpty) return null;
    List current = raw;
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
        } else {
          return null;
        }
      }
    }
    return out;
  }

  @visibleForTesting
  static Float32List? flattenMaskForTest(Object? raw) => _flattenMask(raw);
}
