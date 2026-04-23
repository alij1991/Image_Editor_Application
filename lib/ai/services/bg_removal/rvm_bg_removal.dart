import 'dart:typed_data';
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

final _log = AppLogger('RvmBgRemoval');

/// Phase XV.1: Robust Video Matting (MobileNetV3 fp32) background
/// removal.
///
/// RVM is a recurrent matting network — every call it consumes four
/// recurrent state tensors (r1i..r4i) and produces four new state
/// tensors (r1o..r4o). For single-image matting we run the network
/// in "first frame" mode: the state inputs are `[1, 1, 1, 1]` zeros
/// (per the RVM ONNX export convention). The state outputs are
/// discarded.
///
/// Inputs (float32):
///   - `src`: `[1, 3, H, W]` RGB in `[0, 1]`.
///   - `r1i`, `r2i`, `r3i`, `r4i`: `[1, 1, 1, 1]` zero tensors.
///   - `downsample_ratio`: `[1]` — 0.25 matches 1080p-class inputs.
///
/// Outputs (float32):
///   - `fgr`: `[1, 3, H, W]` foreground RGB — not used; the clean
///     estimate introduced its own edge artefacts in field testing
///     (reverted in Phase XVI.9).
///   - `pha`: `[1, 1, H, W]` alpha mask in `[0, 1]`.
///   - `r1o`, `r2o`, `r3o`, `r4o`: recurrent state outputs — ignored.
///
/// The strategy decodes the source at up to 1024 px, resizes to
/// [inputSize], runs inference, and composites the alpha mask back
/// into the source image's own RGBA — matching every other
/// strategy.
class RvmBgRemoval implements BgRemovalStrategy {
  RvmBgRemoval({required this.session});

  /// RVM accepts dynamic input sizes but we standardise on 512 px —
  /// it's the resolution the MobileNetV3 backbone was benchmarked
  /// against and it keeps the recurrent-state tensor shapes small
  /// (r4 is 64 channels × 16 × 16 at 512 px) so the zero input is
  /// cheap to allocate.
  static const int inputSize = 512;

  /// RVM's downsample ratio — 0.25 is the authors' recommendation
  /// for inputs ≤ 1080p (from the README). Lower numbers skip more
  /// aggressively inside the bottleneck; too low and edge quality
  /// drops, too high and the network runs much slower. 0.25 is the
  /// sweet spot for the 512-px input we use here.
  static const double downsampleRatio = 0.25;

  final OrtV2Session session;
  bool _closed = false;

  @override
  BgRemovalStrategyKind get kind => BgRemovalStrategyKind.rvm;

  @override
  Future<ui.Image> removeBackgroundFromPath(String sourcePath) async {
    if (_closed) {
      _log.w('run rejected — session closed', {'path': sourcePath});
      throw const BgRemovalException(
        'RvmBgRemoval is closed',
        kind: BgRemovalStrategyKind.rvm,
      );
    }
    final total = Stopwatch()..start();
    _log.i('run start', {
      'path': sourcePath,
      'inputs': session.inputNames,
      'outputs': session.outputNames,
    });

    final toRelease = <ort.OrtValue?>[];
    List<ort.OrtValue?>? outputs;
    try {
      // 1. Decode source.
      final decoded = await BgRemovalImageIo.decodeFileToRgba(sourcePath);
      _log.d('source decoded', {
        'w': decoded.width,
        'h': decoded.height,
      });

      // 2. Build src tensor — bilinear resize, scale to [0, 1].
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

      // 3. Wrap inputs. The recurrent state tensors can be [1,1,1,1]
      //    zeros on the first (and in our case only) frame — RVM's
      //    exported ONNX detects this and runs the initial-state
      //    branch. One float per tensor keeps allocation trivial.
      final srcValue = ort.OrtValueTensor.createTensorWithDataList(
        tensor.data,
        tensor.shape, // [1, 3, H, W]
      );
      toRelease.add(srcValue);

      ort.OrtValue makeZeroState() {
        final v = ort.OrtValueTensor.createTensorWithDataList(
          Float32List(1),
          const [1, 1, 1, 1],
        );
        toRelease.add(v);
        return v;
      }

      final r1 = makeZeroState();
      final r2 = makeZeroState();
      final r3 = makeZeroState();
      final r4 = makeZeroState();

      final ratio = ort.OrtValueTensor.createTensorWithDataList(
        Float32List.fromList(const [downsampleRatio]),
        const [1],
      );
      toRelease.add(ratio);

      // 4. Resolve input name → OrtValue mapping by substring match
      //    so we tolerate minor naming variants across RVM exports.
      final inputMap = <String, ort.OrtValue>{};
      for (final name in session.inputNames) {
        final lower = name.toLowerCase();
        if (lower == 'src' || lower.endsWith('src')) {
          inputMap[name] = srcValue;
        } else if (lower == 'r1i' || lower.endsWith('r1i')) {
          inputMap[name] = r1;
        } else if (lower == 'r2i' || lower.endsWith('r2i')) {
          inputMap[name] = r2;
        } else if (lower == 'r3i' || lower.endsWith('r3i')) {
          inputMap[name] = r3;
        } else if (lower == 'r4i' || lower.endsWith('r4i')) {
          inputMap[name] = r4;
        } else if (lower.contains('ratio') || lower.contains('downsample')) {
          inputMap[name] = ratio;
        }
      }
      if (inputMap.length != session.inputNames.length) {
        throw BgRemovalException(
          'RVM input mapping incomplete: got '
          '${inputMap.keys.toList()} but model declares '
          '${session.inputNames}',
          kind: BgRemovalStrategyKind.rvm,
        );
      }

      // 5. Run inference. Request `pha` by name so the ORT binding
      //    skips allocating the other outputs we don't need. We fall
      //    back to the full output list when `pha` isn't declared
      //    (variant ONNX exports use `alpha` or `matte`).
      final phaName = _findOutput(session.outputNames, const [
        'pha',
        'alpha',
        'matte',
      ]);
      final inferSw = Stopwatch()..start();
      if (phaName != null) {
        outputs = await session.runTyped(inputMap, outputNames: [phaName]);
      } else {
        outputs = await session.runTyped(inputMap);
      }
      inferSw.stop();
      _log.d('inference', {
        'ms': inferSw.elapsedMilliseconds,
        'phaName': phaName ?? 'outputs[0]',
      });

      if (outputs.isEmpty || outputs.first == null) {
        throw const BgRemovalException(
          'RVM returned no output tensor',
          kind: BgRemovalStrategyKind.rvm,
        );
      }

      // 6. Decode the alpha mask. Output is [1,1,H,W] float32.
      final raw = outputs.first!.value;
      final mask = _flattenMask(raw);
      if (mask == null) {
        throw const BgRemovalException(
          'RVM alpha output shape unrecognized',
          kind: BgRemovalStrategyKind.rvm,
        );
      }
      final stats = MaskStats.compute(mask);
      _log.d('mask stats', stats.toLogMap());
      if (stats.isEffectivelyEmpty) {
        _log.w('mask is effectively empty', stats.toLogMap());
      } else if (stats.isEffectivelyFull) {
        _log.w('mask is effectively full', stats.toLogMap());
      }

      // 7. Blend into the source RGBA (upscales mask back to source).
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

      // 8. Re-upload as a ui.Image.
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
      });
      return cutout;
    } on BgRemovalException {
      rethrow;
    } on BgRemovalIoException catch (e) {
      _log.w('run IO failure — rewrapping', {'message': e.message});
      throw BgRemovalException(
        e.message,
        kind: BgRemovalStrategyKind.rvm,
      );
    } catch (e, st) {
      total.stop();
      _log.e('run failed',
          error: e, stackTrace: st, data: {'ms': total.elapsedMilliseconds});
      throw BgRemovalException(
        e.toString(),
        kind: BgRemovalStrategyKind.rvm,
        cause: e,
      );
    } finally {
      for (final v in toRelease) {
        try {
          v?.release();
        } catch (e) {
          _log.w('input release failed', {'error': e.toString()});
        }
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

  /// First matching name from [candidates] that appears in
  /// [outputs] (case-insensitive suffix match). Returns null when
  /// none match.
  @visibleForTesting
  static String? findOutputForTest(
    List<String> outputs,
    List<String> candidates,
  ) =>
      _findOutput(outputs, candidates);

  static String? _findOutput(List<String> outputs, List<String> candidates) {
    for (final c in candidates) {
      for (final n in outputs) {
        final lower = n.toLowerCase();
        if (lower == c || lower.endsWith(c)) return n;
      }
    }
    return null;
  }

  /// Walk a nested `[1][1][H][W]` list tensor (what OrtValue.value
  /// returns) into a flat [Float32List]. Returns null when the
  /// shape is unexpected.
  ///
  /// Exposed for tests via [flattenMaskForTest].
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
