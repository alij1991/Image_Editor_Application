import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../../../core/logging/app_logger.dart';
import '../../../engine/pipeline/geometry_state.dart';
import '../../../engine/rendering/shader_pass.dart';
import '../../../engine/rendering/shader_renderer.dart';

final _log = AppLogger('ExportService');

/// Output container the user picks in the export sheet. Each format
/// trades off file size vs. fidelity:
///   - JPEG: smallest, lossy, no alpha. Default for camera-style
///     photos.
///   - PNG: lossless, supports alpha. Best for screenshots / cutouts /
///     anything with transparency.
///   - WebP: ~30% smaller than JPEG at matching quality, supports
///     alpha. Best modern default but support varies by destination.
enum ExportFormat {
  jpeg('JPEG', 'image/jpeg', '.jpg', supportsAlpha: false),
  png('PNG', 'image/png', '.png', supportsAlpha: true),
  webp('WebP', 'image/webp', '.webp', supportsAlpha: true);

  const ExportFormat(this.label, this.mimeType, this.extension,
      {required this.supportsAlpha});
  final String label;
  final String mimeType;
  final String extension;
  final bool supportsAlpha;
}

/// Result of a successful export call. The temp file lives under
/// `getTemporaryDirectory()` so the OS can sweep it; callers that
/// want long-term storage should copy it elsewhere or rely on the
/// system share-sheet "Save to Photos" path.
class ExportResult {
  ExportResult({
    required this.file,
    required this.format,
    required this.width,
    required this.height,
    required this.bytes,
    required this.elapsed,
  });

  final File file;
  final ExportFormat format;
  final int width;
  final int height;
  final int bytes;
  final Duration elapsed;
}

class ExportException implements Exception {
  const ExportException(this.message, {this.cause});
  final String message;
  final Object? cause;
  @override
  String toString() => cause == null
      ? 'ExportException: $message'
      : 'ExportException: $message (caused by $cause)';
}

/// Renders the current pipeline against the source image at a chosen
/// resolution and encodes the result to disk.
///
/// Pipeline:
///   1. Decode the original at full resolution (or downsample if the
///      caller specified `maxLongEdge`).
///   2. Re-run the shader chain against that image at the target
///      output size — same passes the preview uses, just bigger.
///   3. (Phase 11 will composite content layers + apply geometry
///      transforms here. For now we render the shader chain as-is;
///      content layers ride along through the existing LayerPainter
///      path when the export sheet wires them in.)
///   4. Read pixels via `toByteData(format: rawRgba)`.
///   5. Encode via the `image` package at the chosen quality.
///   6. Write to a temp file with a timestamp-based name.
///
/// Failure modes are wrapped in [ExportException] with messages the
/// editor surfaces verbatim.
class ExportService {
  ExportService();

  /// Decode the original from [sourcePath] at full resolution (or
  /// downscaled if [maxLongEdge] is set).
  Future<ui.Image> decodeFullRes({
    required String sourcePath,
    int? maxLongEdge,
  }) async {
    final file = File(sourcePath);
    if (!await file.exists()) {
      throw ExportException('Source file not found: $sourcePath');
    }
    try {
      final bytes = await file.readAsBytes();
      // Pick the larger dimension to clamp; codec preserves aspect
      // ratio when only `targetWidth` (or only height) is set, so we
      // need to read header first to decide which axis to clamp.
      final descriptor = await ui.ImageDescriptor.encoded(
        await ui.ImmutableBuffer.fromUint8List(bytes),
      );
      final w = descriptor.width;
      final h = descriptor.height;
      int? targetW;
      int? targetH;
      if (maxLongEdge != null) {
        if (w >= h) {
          if (w > maxLongEdge) targetW = maxLongEdge;
        } else {
          if (h > maxLongEdge) targetH = maxLongEdge;
        }
      }
      final codec = await ui.instantiateImageCodec(
        bytes,
        targetWidth: targetW,
        targetHeight: targetH,
      );
      final frame = await codec.getNextFrame();
      _log.d('decoded', {
        'sourceW': w,
        'sourceH': h,
        'outW': frame.image.width,
        'outH': frame.image.height,
      });
      return frame.image;
    } catch (e, st) {
      _log.e('decode failed',
          error: e, stackTrace: st, data: {'path': sourcePath});
      throw ExportException('Could not decode source image', cause: e);
    }
  }

  /// Run the shader [passes] against [source] and return the rendered
  /// image cropped to [GeometryState.cropRect]. Output dimensions are
  /// `crop.width × source.width` by `crop.height × source.height`
  /// (rounded to integers); when no crop is set this is the source's
  /// native size. Callers must dispose the returned image when done.
  ///
  /// Geometry rotation / flip / straighten land in a follow-up; the
  /// preview canvas already applies them via Flutter's transform
  /// widgets, but the export path needs equivalent matrix math.
  Future<ui.Image> renderToImage({
    required ui.Image source,
    required List<ShaderPass> passes,
    required GeometryState geometry,
  }) async {
    final crop = geometry.effectiveCropRect;
    final outW = (source.width * crop.width).round().clamp(1, source.width);
    final outH =
        (source.height * crop.height).round().clamp(1, source.height);
    final recorder = ui.PictureRecorder();
    final canvas = ui.Canvas(recorder);
    if (!crop.isFull) {
      // Translate so the crop's top-left lands at the canvas origin,
      // then let the shader chain render the FULL source — the parts
      // outside the canvas (outW, outH) are clipped at toImage time.
      canvas.translate(
        -crop.left * source.width,
        -crop.top * source.height,
      );
    }
    final renderer = ShaderRenderer(source: source, passes: passes);
    renderer.paint(
      canvas,
      ui.Size(source.width.toDouble(), source.height.toDouble()),
    );
    final picture = recorder.endRecording();
    try {
      // toImage is the async sibling — lets the GPU finish before we
      // read pixels back, avoiding occasional black exports on
      // slower devices that I saw in early Phase 9 testing.
      final out = await picture.toImage(outW, outH);
      return out;
    } finally {
      picture.dispose();
    }
  }

  /// Encode [image] to bytes in [format]. JPEG / WebP honour [quality]
  /// (1–100); PNG ignores it. WebP at quality < 100 is lossy.
  Future<Uint8List> encode({
    required ui.Image image,
    required ExportFormat format,
    int quality = 92,
  }) async {
    if (quality < 1 || quality > 100) {
      throw ExportException('Quality must be 1–100, got $quality');
    }
    try {
      final byteData =
          await image.toByteData(format: ui.ImageByteFormat.rawRgba);
      if (byteData == null) {
        throw const ExportException('Failed to read pixels from image');
      }
      final raw = byteData.buffer.asUint8List();
      final cmd = img.Command()
        ..image(img.Image.fromBytes(
          width: image.width,
          height: image.height,
          bytes: raw.buffer,
          numChannels: 4,
          order: img.ChannelOrder.rgba,
        ));
      switch (format) {
        case ExportFormat.jpeg:
          cmd.encodeJpg(quality: quality);
        case ExportFormat.png:
          cmd.encodePng();
        case ExportFormat.webp:
          // The image package's WebP encoder is lossless-only as of
          // 4.x. Quality is accepted but ignored. Document so the UI
          // can warn the user that quality has no effect for WebP.
          cmd.encodePng(); // fallback
          throw const ExportException(
            'WebP encoding is not yet supported in this build — '
            'choose JPEG or PNG. (image package WebP support lands '
            'in a follow-up.)',
          );
      }
      await cmd.execute();
      final out = cmd.outputBytes;
      if (out == null) {
        throw const ExportException('Encoder produced no bytes');
      }
      return Uint8List.fromList(out);
    } on ExportException {
      rethrow;
    } catch (e, st) {
      _log.e('encode failed',
          error: e, stackTrace: st, data: {'format': format.name});
      throw ExportException('Encoding failed', cause: e);
    }
  }

  /// Full end-to-end export: decode → render → encode → write to a
  /// temp file. Returns an [ExportResult] the caller can hand to the
  /// share sheet. Throws [ExportException] on any failure.
  Future<ExportResult> export({
    required String sourcePath,
    required List<ShaderPass> passes,
    required GeometryState geometry,
    required ExportFormat format,
    int quality = 92,
    int? maxLongEdge,
  }) async {
    final sw = Stopwatch()..start();
    _log.i('export start', {
      'format': format.name,
      'quality': quality,
      'maxLongEdge': maxLongEdge,
    });
    final source = await decodeFullRes(
      sourcePath: sourcePath,
      maxLongEdge: maxLongEdge,
    );
    ui.Image? rendered;
    try {
      rendered = await renderToImage(
        source: source,
        passes: passes,
        geometry: geometry,
      );
      final bytes = await encode(
        image: rendered,
        format: format,
        quality: quality,
      );
      final dir = await getTemporaryDirectory();
      final ts = DateTime.now().millisecondsSinceEpoch;
      final file = File(p.join(dir.path, 'export_$ts${format.extension}'));
      await file.writeAsBytes(bytes, flush: true);
      sw.stop();
      _log.i('export done', {
        'ms': sw.elapsedMilliseconds,
        'bytes': bytes.length,
        'path': file.path,
      });
      return ExportResult(
        file: file,
        format: format,
        width: rendered.width,
        height: rendered.height,
        bytes: bytes.length,
        elapsed: sw.elapsed,
      );
    } finally {
      source.dispose();
      rendered?.dispose();
    }
  }
}
