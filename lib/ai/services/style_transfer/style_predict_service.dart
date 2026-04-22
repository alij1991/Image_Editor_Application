import 'dart:typed_data';

import '../../../core/logging/app_logger.dart';
import '../../runtime/litert_runtime.dart';
import '../bg_removal/image_io.dart';
import 'style_vector_cache.dart';

final _log = AppLogger('StylePredictService');

/// Runs the Magenta style prediction model on a style reference image
/// to extract a 100-dimensional style bottleneck vector.
///
/// Input:  `[1, 256, 256, 3]` float32 in `[0, 1]` (HWC)
/// Output: `[1, 1, 1, 100]` float32 style bottleneck
class StylePredictService {
  StylePredictService({required this.session});

  static const int inputSize = 256;
  static const int vectorLength = 100;

  final LiteRtSession session;
  bool _closed = false;

  /// Extract a style vector from the image at [stylePath].
  ///
  /// Phase V.5: if [cache] is provided, [stylePath]'s file bytes are
  /// hashed and looked up first; a hit skips the entire ML Kit run.
  /// Misses compute and persist for future invocations (across
  /// sessions). Passing `null` preserves the pre-V.5 always-compute
  /// behavior for callers that explicitly don't want caching.
  Future<Float32List> predictFromPath(
    String stylePath, {
    StyleVectorCache? cache,
  }) async {
    if (_closed) throw const StylePredictException('Service is closed');
    if (cache != null) {
      return cache.getOrCompute(
        stylePath: stylePath,
        compute: () => _predictUncached(stylePath),
      );
    }
    return _predictUncached(stylePath);
  }

  /// Uncached compute path — runs the full decode + tensor + ML Kit
  /// pipeline. Extracted from [predictFromPath] so [StyleVectorCache]
  /// can inject itself between the sha-lookup and the expensive work.
  Future<Float32List> _predictUncached(String stylePath) async {
    final sw = Stopwatch()..start();
    _log.i('predict start', {'path': stylePath});

    try {
      final decoded = await BgRemovalImageIo.decodeFileToRgba(
        stylePath,
        maxDimension: inputSize,
      );
      _log.d('style image decoded', {
        'w': decoded.width,
        'h': decoded.height,
      });

      // Build HWC tensor [1, 256, 256, 3].
      final tensor = _buildHwcTensor(
        rgba: decoded.bytes,
        srcWidth: decoded.width,
        srcHeight: decoded.height,
      );

      // Output: [1, 1, 1, 100].
      final output = List.generate(
        1,
        (_) => List.generate(
          1,
          (_) => List.generate(
            1,
            (_) => List<double>.filled(vectorLength, 0.0),
          ),
        ),
      );

      await session.runTyped([tensor], {0: output});

      // Flatten [1][1][1][100] → Float32List(100).
      final vector = Float32List(vectorLength);
      for (int i = 0; i < vectorLength; i++) {
        vector[i] = output[0][0][0][i];
      }

      sw.stop();
      _log.i('predict complete', {
        'ms': sw.elapsedMilliseconds,
        'min': vector.reduce((a, b) => a < b ? a : b).toStringAsFixed(3),
        'max': vector.reduce((a, b) => a > b ? a : b).toStringAsFixed(3),
      });
      return vector;
    } catch (e, st) {
      sw.stop();
      _log.e('predict failed', error: e, stackTrace: st);
      throw StylePredictException(e.toString(), cause: e);
    }
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _log.i('close');
    await session.close();
  }

  static List<List<List<List<double>>>> _buildHwcTensor({
    required Uint8List rgba,
    required int srcWidth,
    required int srcHeight,
  }) {
    final yScale = (srcHeight - 1) / (inputSize > 1 ? inputSize - 1 : 1);
    final xScale = (srcWidth - 1) / (inputSize > 1 ? inputSize - 1 : 1);

    return [
      List.generate(inputSize, (y) {
        final sy = y * yScale;
        final y0 = sy.floor().clamp(0, srcHeight - 1);
        final y1 = (y0 + 1).clamp(0, srcHeight - 1);
        final wy = sy - y0;
        return List.generate(inputSize, (x) {
          final sx = x * xScale;
          final x0 = sx.floor().clamp(0, srcWidth - 1);
          final x1 = (x0 + 1).clamp(0, srcWidth - 1);
          final wx = sx - x0;

          final i00 = (y0 * srcWidth + x0) * 4;
          final i01 = (y0 * srcWidth + x1) * 4;
          final i10 = (y1 * srcWidth + x0) * 4;
          final i11 = (y1 * srcWidth + x1) * 4;

          final r = ((rgba[i00] * (1 - wx) + rgba[i01] * wx) * (1 - wy) +
                  (rgba[i10] * (1 - wx) + rgba[i11] * wx) * wy) /
              255.0;
          final g =
              ((rgba[i00 + 1] * (1 - wx) + rgba[i01 + 1] * wx) * (1 - wy) +
                      (rgba[i10 + 1] * (1 - wx) + rgba[i11 + 1] * wx) * wy) /
                  255.0;
          final b =
              ((rgba[i00 + 2] * (1 - wx) + rgba[i01 + 2] * wx) * (1 - wy) +
                      (rgba[i10 + 2] * (1 - wx) + rgba[i11 + 2] * wx) * wy) /
                  255.0;
          return [r, g, b];
        });
      })
    ];
  }
}

class StylePredictException implements Exception {
  const StylePredictException(this.message, {this.cause});
  final String message;
  final Object? cause;

  @override
  String toString() => 'StylePredictException: $message';
}
