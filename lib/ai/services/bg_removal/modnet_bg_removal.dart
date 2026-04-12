import 'dart:typed_data';
import 'dart:ui' as ui;

import '../../../core/logging/app_logger.dart';
import '../../inference/image_tensor.dart';
import '../../inference/mask_stats.dart';
import '../../inference/mask_to_alpha.dart';
import '../../runtime/litert_runtime.dart';
import 'bg_removal_strategy.dart';
import 'image_io.dart';

final _log = AppLogger('ModNetBgRemoval');

/// Background removal via MODNet (downloaded TFLite model).
///
/// MODNet is a portrait-matting network that outputs a soft alpha
/// matte with noticeably better hair / edge detail than MediaPipe.
/// Input: `[1, 3, 512, 512]` float32 in `[-1, 1]`
/// Output: `[1, 1, 512, 512]` float32 in `[0, 1]`
///
/// The strategy owns a [LiteRtSession] for its lifetime; callers
/// should reuse the instance across multiple `removeBackgroundFromPath`
/// calls to avoid reloading the 7 MB model. On [close], the session
/// is released.
class ModNetBgRemoval implements BgRemovalStrategy {
  ModNetBgRemoval({required this.session});

  /// Expected spatial resolution for MODNet's input tensor.
  static const int inputSize = 512;

  /// Per-channel normalization: maps `[0, 1]` pixels to `[-1, 1]`.
  static const List<double> _mean = [0.5, 0.5, 0.5];
  static const List<double> _std = [0.5, 0.5, 0.5];

  final LiteRtSession session;
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

      // 3. Run inference. MODNet's TFLite export expects a nested
      //    List<List<List<List<double>>>> — the typed helpers on
      //    ImageTensor produce exactly that form.
      final input = tensor.asNested();
      final output = List.generate(
        1,
        (_) => List.generate(
          1,
          (_) => List.generate(
            inputSize,
            (_) => List.filled(inputSize, 0.0),
          ),
        ),
      );
      final inferSw = Stopwatch()..start();
      await session.runTyped([input], {0: output});
      inferSw.stop();
      _log.d('inference', {
        'ms': inferSw.elapsedMilliseconds,
        'nativeMicros': session.lastInferenceMicros,
      });

      // 4. Flatten the output into a Float32List.
      final mask = Float32List(inputSize * inputSize);
      for (int y = 0; y < inputSize; y++) {
        for (int x = 0; x < inputSize; x++) {
          mask[y * inputSize + x] = output[0][0][y][x];
        }
      }

      // Sanity-check the mask so pathological all-zero / all-one
      // outputs surface in the logs instead of silently producing a
      // blank cutout. Catches normalization mismatches + wrong
      // output slot reads.
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
    }
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _log.i('close');
    await session.close();
  }
}
