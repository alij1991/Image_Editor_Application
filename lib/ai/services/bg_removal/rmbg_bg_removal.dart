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

final _log = AppLogger('RmbgBgRemoval');

/// Background removal via RMBG-1.4 int8 (downloaded ONNX model).
///
/// RMBG-1.4 is a general-purpose matting network trained on diverse
/// subjects (people, pets, objects). Compared to MODNet it's larger
/// (~44 MB int8), slower, and handles non-portrait scenes that
/// portrait-matters fail on.
///
/// Input:  `[1, 3, 1024, 1024]` float32 in `[0, 1]`
/// Output: `[1, 1, 1024, 1024]` float32 in `[0, 1]`
///
/// We rely on the 9c [OrtRuntime] to have the session ready. Ownership
/// of the session transfers to this strategy — [close] releases it.
class RmbgBgRemoval implements BgRemovalStrategy {
  RmbgBgRemoval({required this.session});

  /// RMBG-1.4's native input size.
  static const int inputSize = 1024;

  final OrtV2Session session;
  bool _closed = false;

  @override
  BgRemovalStrategyKind get kind => BgRemovalStrategyKind.rmbg;

  @override
  Future<ui.Image> removeBackgroundFromPath(String sourcePath) async {
    if (_closed) {
      _log.w('run rejected — session closed', {'path': sourcePath});
      throw const BgRemovalException(
        'RmbgBgRemoval is closed',
        kind: BgRemovalStrategyKind.rmbg,
      );
    }
    final total = Stopwatch()..start();
    _log.i('run start', {
      'path': sourcePath,
      'inputs': session.inputNames,
      'outputs': session.outputNames,
    });
    ort.OrtValue? inputValue;
    // Output tensors are collected into this list as soon as the
    // session returns so the `finally` block can release every one
    // even if the postprocessing step throws mid-run. Native pointers
    // are NOT Dart-GC-managed, so without explicit release the ORT
    // runtime leaks the tensor memory per failed call.
    List<ort.OrtValue?>? outputs;
    try {
      // 1. Decode source image into raw RGBA.
      final decoded = await BgRemovalImageIo.decodeFileToRgba(sourcePath);
      _log.d('source decoded', {
        'path': sourcePath,
        'w': decoded.width,
        'h': decoded.height,
      });

      // 2. Build the input tensor (bilinear resize, [0, 1] scale).
      final preSw = Stopwatch()..start();
      final tensor = ImageTensor.fromRgba(
        rgba: decoded.bytes,
        srcWidth: decoded.width,
        srcHeight: decoded.height,
        dstWidth: inputSize,
        dstHeight: inputSize,
      );
      preSw.stop();
      _log.d('preprocessed', {'ms': preSw.elapsedMilliseconds});

      // 3. Wrap the flat Float32List in an OrtValueTensor. The ORT
      //    package expects the data to be shaped via a nested list
      //    even when it's a dense tensor — we build it just once.
      if (session.inputNames.isEmpty) {
        throw const BgRemovalException(
          'RMBG session has no named inputs — model metadata is corrupt',
          kind: BgRemovalStrategyKind.rmbg,
        );
      }
      final inputName = session.inputNames.first;
      inputValue = ort.OrtValueTensor.createTensorWithDataList(
        tensor.data,
        tensor.shape,
      );

      // 4. Run inference on a one-off isolate.
      final inferSw = Stopwatch()..start();
      outputs = await session.runTyped({inputName: inputValue});
      inferSw.stop();
      _log.d('inference', {'ms': inferSw.elapsedMilliseconds});

      if (outputs.isEmpty || outputs.first == null) {
        throw const BgRemovalException(
          'RMBG returned no output tensor',
          kind: BgRemovalStrategyKind.rmbg,
        );
      }

      // 5. Extract the float mask. The output is a dense [1,1,H,W]
      //    tensor; .value gives us nested lists back.
      final raw = outputs.first!.value;
      final mask = _flattenMask(raw);
      if (mask == null) {
        throw const BgRemovalException(
          'RMBG output shape unrecognized',
          kind: BgRemovalStrategyKind.rmbg,
        );
      }
      // Sanity-check the mask so pathological all-zero / all-one
      // outputs surface in the logs instead of silently producing a
      // blank cutout. Helpful when debugging "the model ran but the
      // result is transparent / opaque".
      final stats = MaskStats.compute(mask);
      _log.d('mask stats', stats.toLogMap());
      if (stats.isEffectivelyEmpty) {
        _log.w('mask is effectively empty', stats.toLogMap());
      } else if (stats.isEffectivelyFull) {
        _log.w('mask is effectively full (subject covers whole image?)',
            stats.toLogMap());
      }

      // 6. Blend into the source alpha channel.
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

      // 7. Re-upload as a ui.Image.
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
        kind: BgRemovalStrategyKind.rmbg,
      );
    } catch (e, st) {
      total.stop();
      _log.e('run failed',
          error: e, stackTrace: st, data: {'ms': total.elapsedMilliseconds});
      throw BgRemovalException(
        e.toString(),
        kind: BgRemovalStrategyKind.rmbg,
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

  /// Walk a nested `[1][1][H][W]` list-of-doubles tensor (which is
  /// what `OrtValue.value` returns for a dense float tensor) into a
  /// flat [Float32List]. Returns null if the shape doesn't match.
  ///
  /// Exposed for tests via [flattenMaskForTest].
  static Float32List? _flattenMask(Object? raw) {
    if (raw is! List || raw.isEmpty) return null;
    // Drop leading batch/channel dimensions. RMBG returns [1][1][H][W]:
    // advance into the innermost 2D matrix by peeking two levels down.
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

  /// Visible-for-tests entry point — exercises [_flattenMask] without
  /// loading an ONNX session.
  @visibleForTesting
  static Float32List? flattenMaskForTest(Object? raw) => _flattenMask(raw);
}

