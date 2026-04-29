import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:onnxruntime_v2/onnxruntime_v2.dart' as ort;

import '../../../core/logging/app_logger.dart';
import '../../inference/image_tensor.dart';
import '../../runtime/ort_runtime.dart';
import '../bg_removal/image_io.dart';

final _log = AppLogger('PhotoWctService');

/// Phase XVI.57 — PhotoWCT2 photoreal style transfer.
///
/// The audit plan and harmonization plan (XVI.31) called for
/// PhotoWCT2 (Chiu & Gurari, WACV 2022 — github.com/chiutaiyin/
/// PhotoWCT2). 7.05 M params, photoreal — does NOT add brushwork.
/// Drives the "Match scene aesthetic" tier alongside the existing
/// Magenta arbitrary style transfer (which IS brushwork-adding).
///
/// ## I/O contract
///
/// **Inputs:** two CHW tensors at [inputSize] × [inputSize]:
///   - `content` — `[1, 3, H, W]` float32 in `[0, 1]`. The image
///     whose CONTENT is preserved.
///   - `style` — `[1, 3, H, W]` float32 in `[0, 1]`. The image
///     whose AESTHETIC (palette, contrast, atmosphere) is
///     transferred onto the content.
///
/// **Output:** `[1, 3, H, W]` float32 in `[0, 1]` — the photoreal
/// stylised result. Network is fully-convolutional but typical
/// community exports fix the spatial dimensions; we run at 512 px.
///
/// ## Pipeline
///
/// 1. Decode content + style sources to RGBA (capped at 1024 px).
/// 2. Build CHW float tensors for each (no ImageNet normalization
///    — PhotoWCT2 trains on `[0, 1]` directly via VGG-16 features).
/// 3. Single ORT inference call with both inputs.
/// 4. Reshape output → CHW Float32List.
/// 5. Bilinear-resize back to the content's original dimensions
///    and pack to RGBA.
/// 6. Re-upload as a `ui.Image`.
///
/// Silent fallback per project convention.
class PhotoWctService {
  PhotoWctService({
    required this.session,
    this.inputSize = 512,
  });

  /// Native input edge length the network runs at. PhotoWCT2 trains
  /// at variable resolution but community ONNX exports typically
  /// fix the spatial dimensions; 512 keeps inference fast on phone
  /// CPUs while preserving enough detail for the content path.
  final int inputSize;

  final OrtV2Session session;
  bool _closed = false;

  /// Run PhotoWCT2 on (content, style). Returns a `ui.Image` at the
  /// content image's decoded dimensions with the style transferred.
  Future<ui.Image> transferFromPaths({
    required String contentPath,
    required String stylePath,
  }) async {
    if (_closed) {
      _log.w('run rejected — session closed');
      throw const PhotoWctException('PhotoWctService is closed');
    }
    final total = Stopwatch()..start();
    _log.i('run start', {
      'content': contentPath,
      'style': stylePath,
      'inputs': session.inputNames,
      'outputs': session.outputNames,
      'inputSize': inputSize,
    });

    ort.OrtValue? contentValue;
    ort.OrtValue? styleValue;
    List<ort.OrtValue?>? outputs;
    try {
      // 1. Decode both sources.
      final contentDecoded = await BgRemovalImageIo.decodeFileToRgba(
        contentPath,
      );
      final styleDecoded = await BgRemovalImageIo.decodeFileToRgba(stylePath);
      _log.d('sources decoded', {
        'cw': contentDecoded.width,
        'ch': contentDecoded.height,
        'sw': styleDecoded.width,
        'sh': styleDecoded.height,
      });

      // 2. Build CHW tensors at inputSize × inputSize, no normalisation.
      final preSw = Stopwatch()..start();
      final contentTensor = ImageTensor.fromRgba(
        rgba: contentDecoded.bytes,
        srcWidth: contentDecoded.width,
        srcHeight: contentDecoded.height,
        dstWidth: inputSize,
        dstHeight: inputSize,
      );
      final styleTensor = ImageTensor.fromRgba(
        rgba: styleDecoded.bytes,
        srcWidth: styleDecoded.width,
        srcHeight: styleDecoded.height,
        dstWidth: inputSize,
        dstHeight: inputSize,
      );
      preSw.stop();
      _log.d('preprocessed', {'ms': preSw.elapsedMilliseconds});

      // 3. Resolve declared input names — PhotoWCT2 typically uses
      //    'content' and 'style', but tolerate variants.
      final names = pickInputNames(session.inputNames);
      if (names == null) {
        throw PhotoWctException(
          'Could not resolve content + style input names from '
          '${session.inputNames}',
        );
      }

      contentValue = ort.OrtValueTensor.createTensorWithDataList(
        contentTensor.data,
        contentTensor.shape,
      );
      styleValue = ort.OrtValueTensor.createTensorWithDataList(
        styleTensor.data,
        styleTensor.shape,
      );

      // 4. Run inference.
      final inferSw = Stopwatch()..start();
      outputs = await session.runTyped({
        names.content: contentValue,
        names.style: styleValue,
      });
      inferSw.stop();
      _log.d('inference', {'ms': inferSw.elapsedMilliseconds});

      if (outputs.isEmpty || outputs.first == null) {
        throw const PhotoWctException(
          'PhotoWCT2 returned no output tensor',
        );
      }

      // 5. Flatten → CHW.
      final styledChw = flattenChw(outputs.first!.value);
      if (styledChw == null) {
        throw const PhotoWctException(
          'PhotoWCT2 output shape unrecognised — expected [1, 3, H, W]',
        );
      }

      // 6. Resize back to content's source dimensions + pack to RGBA.
      final postSw = Stopwatch()..start();
      final rgba = chwToRgba(
        chw: styledChw,
        chwSize: inputSize,
        dstWidth: contentDecoded.width,
        dstHeight: contentDecoded.height,
      );
      postSw.stop();
      _log.d('postprocessed', {'ms': postSw.elapsedMilliseconds});

      // 7. Upload as ui.Image.
      final image = await BgRemovalImageIo.encodeRgbaToUiImage(
        rgba: rgba,
        width: contentDecoded.width,
        height: contentDecoded.height,
      );
      total.stop();
      _log.i('run complete', {
        'totalMs': total.elapsedMilliseconds,
        'preMs': preSw.elapsedMilliseconds,
        'inferMs': inferSw.elapsedMilliseconds,
        'postMs': postSw.elapsedMilliseconds,
      });
      return image;
    } on PhotoWctException {
      rethrow;
    } on BgRemovalIoException catch (e) {
      _log.w('run IO failure — rewrapping', {'message': e.message});
      throw PhotoWctException(e.message, cause: e);
    } catch (e, st) {
      total.stop();
      _log.e('run failed',
          error: e, stackTrace: st, data: {'ms': total.elapsedMilliseconds});
      throw PhotoWctException(e.toString(), cause: e);
    } finally {
      try {
        contentValue?.release();
      } catch (e) {
        _log.w('content release failed', {'error': e.toString()});
      }
      try {
        styleValue?.release();
      } catch (e) {
        _log.w('style release failed', {'error': e.toString()});
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

  /// Resolve the session's two input names to the (content, style)
  /// pair. Most PhotoWCT2 ONNX exports use literal 'content' and
  /// 'style'; we also tolerate '{content,style}_image', or
  /// '{c,s}'-style abbreviations for robustness across community
  /// exports. Returns null when either role can't be matched —
  /// callers throw a typed exception so the AI coordinator can
  /// fall back to the Magenta scaffold.
  @visibleForTesting
  static InputNamePair? pickInputNames(List<String> names) {
    if (names.length < 2) return null;
    String? content;
    String? style;
    for (final n in names) {
      final lower = n.toLowerCase();
      if (content == null &&
          (lower == 'content' ||
              lower == 'content_image' ||
              lower == 'c' ||
              lower.endsWith('content'))) {
        content = n;
      } else if (style == null &&
          (lower == 'style' ||
              lower == 'style_image' ||
              lower == 's' ||
              lower.endsWith('style'))) {
        style = n;
      }
    }
    // If neither role matched, fall back to positional: first =
    // content, second = style. PhotoWCT2's published ONNX export
    // uses this declared order.
    content ??= names.first;
    style ??= names[1];
    if (content == style) return null;
    return InputNamePair(content: content, style: style);
  }

  /// Walk a nested `[1, 3, H, W]` (or `[3, H, W]`) tensor into a flat
  /// CHW Float32List. Returns null when the shape doesn't match.
  @visibleForTesting
  static Float32List? flattenChw(Object? raw) {
    if (raw is! List || raw.isEmpty) return null;
    List current = raw;
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

  /// Bilinearly resample a CHW float tensor at `chwSize × chwSize`
  /// to `dstWidth × dstHeight` and pack the result as RGBA8 with
  /// fully-opaque alpha.
  @visibleForTesting
  static Uint8List chwToRgba({
    required Float32List chw,
    required int chwSize,
    required int dstWidth,
    required int dstHeight,
  }) {
    final out = Uint8List(dstWidth * dstHeight * 4);
    final hw = chwSize * chwSize;
    final yScale = chwSize > 1 ? (chwSize - 1) / (dstHeight - 1) : 0.0;
    final xScale = chwSize > 1 ? (chwSize - 1) / (dstWidth - 1) : 0.0;
    for (var y = 0; y < dstHeight; y++) {
      final sy = y * yScale;
      final y0 = sy.floor().clamp(0, chwSize - 1);
      final y1 = (y0 + 1).clamp(0, chwSize - 1);
      final wy = sy - y0;
      for (var x = 0; x < dstWidth; x++) {
        final sx = x * xScale;
        final x0 = sx.floor().clamp(0, chwSize - 1);
        final x1 = (x0 + 1).clamp(0, chwSize - 1);
        final wx = sx - x0;

        double sample(int planeOffset) {
          final v00 = chw[planeOffset + y0 * chwSize + x0];
          final v01 = chw[planeOffset + y0 * chwSize + x1];
          final v10 = chw[planeOffset + y1 * chwSize + x0];
          final v11 = chw[planeOffset + y1 * chwSize + x1];
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

/// Resolved (content, style) input name pair.
class InputNamePair {
  const InputNamePair({required this.content, required this.style});
  final String content;
  final String style;

  @override
  bool operator ==(Object other) =>
      other is InputNamePair &&
      other.content == content &&
      other.style == style;

  @override
  int get hashCode => Object.hash(content, style);

  @override
  String toString() => 'InputNamePair(content=$content, style=$style)';
}

/// Stable model id for the downloaded PhotoWCT2 ONNX.
const String kPhotoWctModelId = 'photo_wct2_fp16';

class PhotoWctException implements Exception {
  const PhotoWctException(this.message, {this.cause});
  final String message;
  final Object? cause;

  @override
  String toString() {
    if (cause == null) return 'PhotoWctException: $message';
    return 'PhotoWctException: $message (caused by $cause)';
  }
}
