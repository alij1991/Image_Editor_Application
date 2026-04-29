import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:onnxruntime_v2/onnxruntime_v2.dart' as ort;

import '../../../core/logging/app_logger.dart';
import '../../inference/image_tensor.dart';
import '../../runtime/ort_runtime.dart';
import '../bg_removal/image_io.dart';
import '../face_detect/face_detection_service.dart';

final _log = AppLogger('FaceRestoreService');

/// Phase XVI.56 — AI face restoration tier.
///
/// The audit plan called for GFPGAN/CodeFormer-class face restore.
/// Per the user's XVI.56 selection we ship RestoreFormer++ FP16
/// (Wang et al. 2023, the lighter cousin of GFPGAN/CodeFormer):
///
/// * ~75 MB FP16 ONNX vs GFPGAN-v1.4's ~340 MB FP32 — fits the
///   mobile budget without throwing away too much quality.
/// * Quality close to GFPGAN at a quarter of the size; especially
///   strong on mild-to-moderate degradation, which covers most of
///   the real-world "old phone selfie" use case.
/// * Single ONNX (vs CodeFormer's separate codebook), so the I/O
///   contract stays trivial.
///
/// ## Pipeline
///
/// 1. Decode source to RGBA (capped at 1024 px on long edge).
/// 2. Run face detection → list of `DetectedFace` with bboxes.
/// 3. For each face:
///    a. Expand bbox to a SQUARE crop padded by [bboxPadding] (~30%
///       gives RestoreFormer++ enough hair / forehead context).
///    b. Bilinear-crop the source RGBA to that square + resize to
///       [inputSize] × [inputSize].
///    c. Build CHW float32 tensor in `[-1, 1]` (RestoreFormer++
///       trains on `(x/255 - 0.5) * 2`; many community exports use
///       this convention via mean=0.5 / std=0.5).
///    d. Single ORT inference call.
///    e. Reshape output → CHW Float32List in `[-1, 1]` → unscale to
///       `[0, 1]` → bilinear-resize back to the original square size
///       → paste into the source RGBA at the original bbox position.
/// 4. Re-upload the patched source as a `ui.Image`.
///
/// ## I/O contract
///
/// **Input:** `[1, 3, inputSize, inputSize]` float32 in `[-1, 1]`
/// (mean=[0.5,0.5,0.5], std=[0.5,0.5,0.5]).
///
/// **Output:** `[1, 3, inputSize, inputSize]` float32 in `[-1, 1]`
/// — restored face patch. Postprocessing maps back to `[0, 1]` then
/// 8-bit and pastes into the source.
///
/// Silent fallback per project convention: if the model fails to
/// load, the AI coordinator never instantiates the service — the
/// "Restore Faces" button just stays inactive. No toast.
class FaceRestoreService {
  FaceRestoreService({
    required this.session,
    required this.faceDetector,
    this.inputSize = 512,
    this.bboxPadding = 0.30,
  });

  /// Native input edge length the network runs at. RestoreFormer++
  /// trains at 512×512 face crops; deviating from that hurts quality.
  final int inputSize;

  /// Padding factor applied around each face bbox before square
  /// cropping. 0.30 = expand by 30% on each side, which gives the
  /// network enough context for hair + forehead + chin without
  /// losing detail to over-downsampling.
  final double bboxPadding;

  final OrtV2Session session;
  final FaceDetectionService faceDetector;
  bool _closed = false;

  /// Run face restoration on the source file. Detects every face,
  /// runs RestoreFormer++ on each crop, and pastes the results back
  /// into the source. Returns a `ui.Image` at the decoded source
  /// dimensions; if no faces were found the source is returned
  /// unchanged.
  Future<ui.Image> restoreFromPath(String sourcePath) async {
    if (_closed) {
      _log.w('run rejected — session closed', {'path': sourcePath});
      throw const FaceRestoreException('FaceRestoreService is closed');
    }
    final total = Stopwatch()..start();
    _log.i('run start', {
      'path': sourcePath,
      'inputs': session.inputNames,
      'outputs': session.outputNames,
      'inputSize': inputSize,
      'bboxPadding': bboxPadding,
    });

    try {
      // 1. Decode source.
      final decoded = await BgRemovalImageIo.decodeFileToRgba(sourcePath);
      _log.d('source decoded', {'w': decoded.width, 'h': decoded.height});

      // 2. Face detection.
      final faces = await faceDetector.detectFromPath(sourcePath);
      _log.d('faces', {'count': faces.length});
      if (faces.isEmpty) {
        // Nothing to restore — return source unchanged so the caller
        // can decide whether to surface a "no faces found" hint.
        return BgRemovalImageIo.encodeRgbaToUiImage(
          rgba: decoded.bytes,
          width: decoded.width,
          height: decoded.height,
        );
      }

      // 3. Restore each face. Mutate `decoded.bytes` in place.
      // The inference tensor is recreated per face — we can't share
      // an OrtValue across runs because release semantics are
      // per-call.
      final patched = Uint8List.fromList(decoded.bytes);
      for (var i = 0; i < faces.length; i++) {
        final face = faces[i];
        final box = expandSquareBbox(
          left: face.boundingBox.left,
          top: face.boundingBox.top,
          width: face.boundingBox.width,
          height: face.boundingBox.height,
          imageWidth: decoded.width,
          imageHeight: decoded.height,
          padding: bboxPadding,
        );
        if (box.size <= 1) continue;

        final crop = bilinearCropToSquare(
          rgba: patched,
          srcWidth: decoded.width,
          srcHeight: decoded.height,
          cropX: box.x,
          cropY: box.y,
          cropSize: box.size,
          dstSize: inputSize,
        );

        final inputTensor = ImageTensor.fromRgba(
          rgba: crop,
          srcWidth: inputSize,
          srcHeight: inputSize,
          dstWidth: inputSize,
          dstHeight: inputSize,
          mean: const [0.5, 0.5, 0.5],
          std: const [0.5, 0.5, 0.5],
        );

        final inputName = pickInputName(session.inputNames);
        if (inputName == null) {
          throw FaceRestoreException(
            'No matching input name on session: ${session.inputNames}',
          );
        }

        ort.OrtValue? inputValue;
        List<ort.OrtValue?>? outputs;
        try {
          inputValue = ort.OrtValueTensor.createTensorWithDataList(
            inputTensor.data,
            inputTensor.shape,
          );
          outputs = await session.runTyped({inputName: inputValue});
          if (outputs.isEmpty || outputs.first == null) {
            throw const FaceRestoreException(
              'Face restore model returned no output tensor',
            );
          }
          final restoredChw = flattenChw(outputs.first!.value);
          if (restoredChw == null) {
            throw const FaceRestoreException(
              'Restore output shape unrecognised — expected [1, 3, H, W]',
            );
          }
          // Network output is `[-1, 1]`; map back to `[0, 1]`.
          final unitChw = unscaleSignedChw(restoredChw);

          // Resize to the original square crop size + paste back.
          pasteCropBack(
            patched: patched,
            patchedWidth: decoded.width,
            patchedHeight: decoded.height,
            chw: unitChw,
            chwSize: inputSize,
            cropX: box.x,
            cropY: box.y,
            cropSize: box.size,
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

      // 4. Upload the patched source as ui.Image.
      final image = await BgRemovalImageIo.encodeRgbaToUiImage(
        rgba: patched,
        width: decoded.width,
        height: decoded.height,
      );
      total.stop();
      _log.i('run complete', {
        'totalMs': total.elapsedMilliseconds,
        'faces': faces.length,
      });
      return image;
    } on FaceRestoreException {
      rethrow;
    } on BgRemovalIoException catch (e) {
      _log.w('run IO failure — rewrapping', {'message': e.message});
      throw FaceRestoreException(e.message, cause: e);
    } catch (e, st) {
      total.stop();
      _log.e('run failed',
          error: e, stackTrace: st, data: {'ms': total.elapsedMilliseconds});
      throw FaceRestoreException(e.toString(), cause: e);
    }
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _log.i('close');
    await session.close();
  }

  /// Expand a face bbox to a SQUARE crop padded by [padding] on each
  /// side, clamped to the image bounds. RestoreFormer++ expects a
  /// roughly-centred square face crop; matching that tightens the
  /// face-restoration result back to the bbox region.
  ///
  /// Returns origin + size in source-image pixels. The size may be
  /// less than the bbox edge length when the bbox is near an image
  /// edge — clamping wins over centring in that case so we stay
  /// inside the source.
  @visibleForTesting
  static SquareCrop expandSquareBbox({
    required double left,
    required double top,
    required double width,
    required double height,
    required int imageWidth,
    required int imageHeight,
    required double padding,
  }) {
    // Centre + half-edge of the padded square.
    final cx = left + width / 2;
    final cy = top + height / 2;
    final maxEdge = (width > height ? width : height) * (1 + 2 * padding);
    var half = maxEdge / 2;

    var sx = (cx - half).floor();
    var sy = (cy - half).floor();
    var size = maxEdge.ceil();

    // Clamp to the source bounds. We trim from whichever side is
    // off-image so the result stays a square. If the bbox itself is
    // larger than the image, the whole image becomes the crop.
    if (sx < 0) sx = 0;
    if (sy < 0) sy = 0;
    if (size > imageWidth) size = imageWidth;
    if (size > imageHeight) size = imageHeight;
    if (sx + size > imageWidth) sx = imageWidth - size;
    if (sy + size > imageHeight) sy = imageHeight - size;
    return SquareCrop(x: sx, y: sy, size: size);
  }

  /// Bilinear-crop an RGBA buffer at `(cropX, cropY) → cropX + cropSize`
  /// and resize the result to `dstSize × dstSize`. Used to extract
  /// a face crop at the network's native input resolution.
  @visibleForTesting
  static Uint8List bilinearCropToSquare({
    required Uint8List rgba,
    required int srcWidth,
    required int srcHeight,
    required int cropX,
    required int cropY,
    required int cropSize,
    required int dstSize,
  }) {
    final out = Uint8List(dstSize * dstSize * 4);
    if (cropSize <= 0 || dstSize <= 0) return out;
    final scale = cropSize > 1 ? (cropSize - 1) / (dstSize - 1) : 0.0;
    for (var y = 0; y < dstSize; y++) {
      final sy = cropY + y * scale;
      final y0 = sy.floor().clamp(0, srcHeight - 1);
      final y1 = (y0 + 1).clamp(0, srcHeight - 1);
      final wy = sy - y0;
      for (var x = 0; x < dstSize; x++) {
        final sx = cropX + x * scale;
        final x0 = sx.floor().clamp(0, srcWidth - 1);
        final x1 = (x0 + 1).clamp(0, srcWidth - 1);
        final wx = sx - x0;
        final i00 = (y0 * srcWidth + x0) * 4;
        final i01 = (y0 * srcWidth + x1) * 4;
        final i10 = (y1 * srcWidth + x0) * 4;
        final i11 = (y1 * srcWidth + x1) * 4;
        for (var c = 0; c < 3; c++) {
          final v00 = rgba[i00 + c].toDouble();
          final v01 = rgba[i01 + c].toDouble();
          final v10 = rgba[i10 + c].toDouble();
          final v11 = rgba[i11 + c].toDouble();
          final v = (v00 * (1 - wx) + v01 * wx) * (1 - wy) +
              (v10 * (1 - wx) + v11 * wx) * wy;
          out[(y * dstSize + x) * 4 + c] = v.round().clamp(0, 255);
        }
        out[(y * dstSize + x) * 4 + 3] = 255;
      }
    }
    return out;
  }

  /// Map a `[-1, 1]` CHW tensor back to `[0, 1]` element-wise. Used
  /// after RestoreFormer++ inference (network was trained against
  /// `(x/255 - 0.5) * 2`, so the inverse is `(out + 1) / 2`).
  @visibleForTesting
  static Float32List unscaleSignedChw(Float32List signed) {
    final out = Float32List(signed.length);
    for (var i = 0; i < signed.length; i++) {
      final v = (signed[i] + 1) / 2;
      out[i] = v < 0 ? 0 : (v > 1 ? 1 : v);
    }
    return out;
  }

  /// Bilinearly-resample a CHW tensor (in `[0, 1]`) at `chwSize` and
  /// paste it back into [patched] at `(cropX, cropY) → cropX + cropSize`.
  /// Out-of-bounds writes are clipped.
  @visibleForTesting
  static void pasteCropBack({
    required Uint8List patched,
    required int patchedWidth,
    required int patchedHeight,
    required Float32List chw,
    required int chwSize,
    required int cropX,
    required int cropY,
    required int cropSize,
  }) {
    final hw = chwSize * chwSize;
    final scale = cropSize > 1 ? (chwSize - 1) / (cropSize - 1) : 0.0;
    for (var y = 0; y < cropSize; y++) {
      final dy = cropY + y;
      if (dy < 0 || dy >= patchedHeight) continue;
      final sy = y * scale;
      final y0 = sy.floor().clamp(0, chwSize - 1);
      final y1 = (y0 + 1).clamp(0, chwSize - 1);
      final wy = sy - y0;
      for (var x = 0; x < cropSize; x++) {
        final dx = cropX + x;
        if (dx < 0 || dx >= patchedWidth) continue;
        final sx = x * scale;
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
        final idx = (dy * patchedWidth + dx) * 4;
        patched[idx] = r.round();
        patched[idx + 1] = g.round();
        patched[idx + 2] = b.round();
        // alpha stays as the source's alpha — preserve the channel.
      }
    }
  }

  /// Match the session's declared input name against the common
  /// face-restore naming conventions (input / image / pixel_values
  /// / sample). Falls back to the first declared name when no
  /// candidate matches.
  @visibleForTesting
  static String? pickInputName(List<String> names) {
    const candidates = ['input', 'image', 'pixel_values', 'sample'];
    for (final c in candidates) {
      for (final n in names) {
        final lower = n.toLowerCase();
        if (lower == c || lower.endsWith(c)) return n;
      }
    }
    return names.isEmpty ? null : names.first;
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
}

/// Origin + edge length of a SQUARE crop in source-image pixels.
class SquareCrop {
  const SquareCrop({required this.x, required this.y, required this.size});
  final int x;
  final int y;
  final int size;

  @override
  bool operator ==(Object other) =>
      other is SquareCrop && other.x == x && other.y == y && other.size == size;

  @override
  int get hashCode => Object.hash(x, y, size);

  @override
  String toString() => 'SquareCrop(x=$x, y=$y, size=$size)';
}

/// Stable model id for the downloaded RestoreFormer++ FP32 ONNX.
/// XVI.64 renamed this from `restoreformer_pp_fp16` once the actual
/// published file (dnnagy/RestoreFormerPlusPlus) was verified — the
/// community export ships at FP32 / 298 MB, not the 75 MB FP16 the
/// original entry assumed.
const String kFaceRestoreModelId = 'restoreformer_pp_fp32';

class FaceRestoreException implements Exception {
  const FaceRestoreException(this.message, {this.cause});
  final String message;
  final Object? cause;

  @override
  String toString() {
    if (cause == null) return 'FaceRestoreException: $message';
    return 'FaceRestoreException: $message (caused by $cause)';
  }
}
