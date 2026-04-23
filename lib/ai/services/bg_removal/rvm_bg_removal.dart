import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:onnxruntime_v2/onnxruntime_v2.dart' as ort;

import '../../../core/logging/app_logger.dart';
import '../../inference/image_tensor.dart';
import '../../inference/mask_stats.dart';
import '../../runtime/ort_runtime.dart';
import 'bg_removal_strategy.dart';
import 'image_io.dart';

final _log = AppLogger('RvmBgRemoval');

/// Phase XV.1 + XVI.5: Robust Video Matting (MobileNetV3 fp32) bg
/// removal — now consuming both the alpha (`pha`) AND the cleaned
/// foreground (`fgr`) outputs.
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
///   - `fgr`: `[1, 3, H, W]` cleaned foreground RGB in `[0, 1]` —
///     the network's estimate of the subject colour with the
///     original background removed. Phase XVI.5 pipes this into
///     the subject RGBA directly instead of the (contaminated)
///     source pixels, which eliminates the bright-halo artefact
///     that XVI.2–XVI.4 couldn't fully kill through edge ops alone.
///   - `pha`: `[1, 1, H, W]` alpha mask in `[0, 1]`.
///   - `r1o`, `r2o`, `r3o`, `r4o`: recurrent state outputs — ignored
///     here; released alongside the other outputs.
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

      // 3. Wrap inputs.
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

      // 4. Run inference. Phase XVI.5 requests BOTH `fgr` and `pha`
      //    — fgr so the subject RGB is the model's cleaned
      //    foreground estimate (not the contaminated source
      //    pixels), pha for the alpha channel.
      final phaName = _findOutput(session.outputNames, const [
        'pha',
        'alpha',
        'matte',
      ]);
      final fgrName = _findOutput(session.outputNames, const [
        'fgr',
        'foreground',
      ]);
      final requested = <String>[
        if (fgrName != null) fgrName,
        if (phaName != null) phaName,
      ];
      final inferSw = Stopwatch()..start();
      if (requested.length == 2) {
        outputs = await session.runTyped(inputMap, outputNames: requested);
      } else {
        outputs = await session.runTyped(inputMap);
      }
      inferSw.stop();
      _log.d('inference', {
        'ms': inferSw.elapsedMilliseconds,
        'requested': requested,
      });

      // 5. Decode the two outputs. Either / both names may be
      //    null on variant exports — fall through to the full
      //    outputs list in that case.
      Float32List? mask;
      Float32List? fgr;
      if (requested.length == 2) {
        // Map named requests back to indices — runTyped returns
        // outputs in the order we asked for them.
        fgr = _flattenFgr(outputs[0]?.value);
        mask = _flattenMask(outputs[1]?.value);
      } else {
        // Full outputs: find pha and fgr by name via session's
        // declared output order.
        for (int i = 0; i < session.outputNames.length && i < outputs.length; i++) {
          final name = session.outputNames[i].toLowerCase();
          if (name == 'pha' || name.endsWith('pha') ||
              name == 'alpha' || name.endsWith('alpha') ||
              name == 'matte' || name.endsWith('matte')) {
            mask = _flattenMask(outputs[i]?.value);
          } else if (name == 'fgr' || name.endsWith('fgr') ||
              name == 'foreground' || name.endsWith('foreground')) {
            fgr = _flattenFgr(outputs[i]?.value);
          }
        }
      }

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

      // Phase XVI.6 — diagnostic: log the raw fgr's value range at
      // edge pixels so we can see whether RVM produces out-of-range
      // values. If min < 0 or max > 1 at edge pixels, my byte
      // clamp handles it. If max <= 1 and halo is still visible,
      // the problem is somewhere else in the pipeline.
      if (fgr != null) {
        double fgrMin = double.infinity;
        double fgrMax = -double.infinity;
        double fgrEdgeMin = double.infinity;
        double fgrEdgeMax = -double.infinity;
        int fgrOutOfRange = 0;
        final plane = inputSize * inputSize;
        for (int p = 0; p < plane; p++) {
          final a = mask[p];
          for (int c = 0; c < 3; c++) {
            final v = fgr[c * plane + p];
            if (v < fgrMin) fgrMin = v;
            if (v > fgrMax) fgrMax = v;
            if (v < 0 || v > 1) fgrOutOfRange++;
            if (a > 0.05 && a < 0.95) {
              if (v < fgrEdgeMin) fgrEdgeMin = v;
              if (v > fgrEdgeMax) fgrEdgeMax = v;
            }
          }
        }
        _log.i('fgr range', {
          'globalMin': fgrMin.toStringAsFixed(3),
          'globalMax': fgrMax.toStringAsFixed(3),
          'edgeMin': fgrEdgeMin.toStringAsFixed(3),
          'edgeMax': fgrEdgeMax.toStringAsFixed(3),
          'outOfRangePx': fgrOutOfRange,
        });
      }

      // 6. Compose subject RGBA. Phase XVI.5 prefers the cleaned
      //    fgr when available (decontaminated at the model level)
      //    and falls back to the source RGB if the fgr output
      //    wasn't present in this export.
      final postSw = Stopwatch()..start();
      final Uint8List rgba;
      if (fgr != null) {
        rgba = _buildCleanSubjectRgba(
          fgr: fgr,
          mask: mask,
          tensorSize: inputSize,
          outputWidth: decoded.width,
          outputHeight: decoded.height,
        );
        _log.d('using fgr for clean subject RGB');
      } else {
        // Fallback: legacy path using source RGB + alpha from mask.
        rgba = _legacyBlendMaskIntoRgba(
          mask: mask,
          maskSize: inputSize,
          sourceRgba: decoded.bytes,
          srcWidth: decoded.width,
          srcHeight: decoded.height,
        );
        _log.w('fgr unavailable — falling back to source-RGB blend');
      }
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
        'fgrUsed': fgr != null,
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

  /// Phase XVI.5: walk a nested `[1, 3, H, W]` CHW tensor into a
  /// flat CHW [Float32List] of length `3 * H * W`. Layout:
  /// `out[c * H * W + y * W + x]` is channel c, row y, col x.
  /// Returns null when the shape is unexpected.
  static Float32List? _flattenFgr(Object? raw) {
    if (raw is! List || raw.isEmpty) return null;
    // Expect [batch=1, channels=3, H, W].
    final batch = raw;
    if (batch.first is! List) return null;
    final channels = batch.first as List;
    if (channels.length != 3) return null;
    final rTensor = channels[0];
    if (rTensor is! List) return null;
    final height = rTensor.length;
    if (height == 0) return null;
    final firstRow = rTensor.first;
    if (firstRow is! List) return null;
    final width = firstRow.length;
    if (width == 0) return null;
    final plane = height * width;
    final out = Float32List(3 * plane);
    for (int c = 0; c < 3; c++) {
      final cTensor = channels[c];
      if (cTensor is! List || cTensor.length != height) return null;
      for (int y = 0; y < height; y++) {
        final row = cTensor[y];
        if (row is! List || row.length != width) return null;
        final base = c * plane + y * width;
        for (int x = 0; x < width; x++) {
          final v = row[x];
          if (v is num) {
            out[base + x] = v.toDouble();
          } else {
            return null;
          }
        }
      }
    }
    return out;
  }

  /// Phase XVI.5: bilinearly upsample [fgr] (CHW, in `[0, 1]`) +
  /// [mask] to `[outputWidth, outputHeight]` and pack them into an
  /// RGBA8 buffer. The fgr's clean subject colour becomes the
  /// subject RGB; the mask becomes the alpha channel.
  static Uint8List _buildCleanSubjectRgba({
    required Float32List fgr,
    required Float32List mask,
    required int tensorSize,
    required int outputWidth,
    required int outputHeight,
  }) {
    final plane = tensorSize * tensorSize;
    final out = Uint8List(outputWidth * outputHeight * 4);
    // Sample coordinates follow the (src - 1) / (dst - 1) convention
    // so the first and last output samples land on the tensor edges.
    final yDen = outputHeight > 1 ? outputHeight - 1 : 1;
    final xDen = outputWidth > 1 ? outputWidth - 1 : 1;
    final yScale = (tensorSize - 1) / yDen;
    final xScale = (tensorSize - 1) / xDen;
    for (int oy = 0; oy < outputHeight; oy++) {
      final sy = oy * yScale;
      final y0 = sy.floor().clamp(0, tensorSize - 1);
      final y1 = (y0 + 1).clamp(0, tensorSize - 1);
      final wy = sy - y0;
      for (int ox = 0; ox < outputWidth; ox++) {
        final sx = ox * xScale;
        final x0 = sx.floor().clamp(0, tensorSize - 1);
        final x1 = (x0 + 1).clamp(0, tensorSize - 1);
        final wx = sx - x0;

        final i00 = y0 * tensorSize + x0;
        final i01 = y0 * tensorSize + x1;
        final i10 = y1 * tensorSize + x0;
        final i11 = y1 * tensorSize + x1;

        // Bilinear-sample RGB from the CHW fgr tensor. The clamp
        // to [0, 1] before the ×255 is Phase XVI.6: RVM's fgr
        // computes F = (I - (1-α)B) / α, which blows up at
        // edge pixels where α is near 0. Unclamped, sub-1 alpha
        // pixels produce fgr values > 1 and byte values pinned at
        // 255 — a pure-white halo against dark backgrounds. The
        // clamp caps the bright fringe at the interior's real
        // colour before compositing.
        final r = _bilin(
              fgr[i00], fgr[i01], fgr[i10], fgr[i11], wx, wy,
            ).clamp(0.0, 1.0) *
            255.0;
        final g = _bilin(
              fgr[plane + i00],
              fgr[plane + i01],
              fgr[plane + i10],
              fgr[plane + i11],
              wx,
              wy,
            ).clamp(0.0, 1.0) *
            255.0;
        final b = _bilin(
              fgr[2 * plane + i00],
              fgr[2 * plane + i01],
              fgr[2 * plane + i10],
              fgr[2 * plane + i11],
              wx,
              wy,
            ).clamp(0.0, 1.0) *
            255.0;
        final a =
            _bilin(mask[i00], mask[i01], mask[i10], mask[i11], wx, wy) *
                255.0;

        final i = (oy * outputWidth + ox) * 4;
        out[i] = r.round().clamp(0, 255);
        out[i + 1] = g.round().clamp(0, 255);
        out[i + 2] = b.round().clamp(0, 255);
        out[i + 3] = a.round().clamp(0, 255);
      }
    }
    return out;
  }

  /// Legacy fallback for exports that don't surface fgr. Mirrors
  /// the pre-XVI.5 behaviour: keeps the source's own RGB and
  /// replaces alpha with the upsampled mask.
  static Uint8List _legacyBlendMaskIntoRgba({
    required Float32List mask,
    required int maskSize,
    required Uint8List sourceRgba,
    required int srcWidth,
    required int srcHeight,
  }) {
    final out = Uint8List.fromList(sourceRgba);
    final yDen = srcHeight > 1 ? srcHeight - 1 : 1;
    final xDen = srcWidth > 1 ? srcWidth - 1 : 1;
    final yScale = (maskSize - 1) / yDen;
    final xScale = (maskSize - 1) / xDen;
    for (int oy = 0; oy < srcHeight; oy++) {
      final sy = oy * yScale;
      final y0 = sy.floor().clamp(0, maskSize - 1);
      final y1 = (y0 + 1).clamp(0, maskSize - 1);
      final wy = sy - y0;
      for (int ox = 0; ox < srcWidth; ox++) {
        final sx = ox * xScale;
        final x0 = sx.floor().clamp(0, maskSize - 1);
        final x1 = (x0 + 1).clamp(0, maskSize - 1);
        final wx = sx - x0;
        final a = _bilin(
              mask[y0 * maskSize + x0],
              mask[y0 * maskSize + x1],
              mask[y1 * maskSize + x0],
              mask[y1 * maskSize + x1],
              wx,
              wy,
            ) *
            255.0;
        out[(oy * srcWidth + ox) * 4 + 3] = a.round().clamp(0, 255);
      }
    }
    return out;
  }

  /// 2D bilinear interpolation of four corner values.
  static double _bilin(
      double v00, double v01, double v10, double v11, double wx, double wy) {
    final top = v00 + (v01 - v00) * wx;
    final bot = v10 + (v11 - v10) * wx;
    return top + (bot - top) * wy;
  }

  @visibleForTesting
  static Float32List? flattenMaskForTest(Object? raw) => _flattenMask(raw);

  @visibleForTesting
  static Float32List? flattenFgrForTest(Object? raw) => _flattenFgr(raw);

  @visibleForTesting
  static Uint8List buildCleanSubjectRgbaForTest({
    required Float32List fgr,
    required Float32List mask,
    required int tensorSize,
    required int outputWidth,
    required int outputHeight,
  }) =>
      _buildCleanSubjectRgba(
        fgr: fgr,
        mask: mask,
        tensorSize: tensorSize,
        outputWidth: outputWidth,
        outputHeight: outputHeight,
      );
}
