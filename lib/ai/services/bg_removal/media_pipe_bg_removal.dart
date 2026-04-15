import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:google_mlkit_selfie_segmentation/google_mlkit_selfie_segmentation.dart';

import '../../../core/logging/app_logger.dart';
import 'bg_removal_strategy.dart';

final _log = AppLogger('MediaPipeBgRemoval');

/// Background removal via Google ML Kit's Selfie Segmenter.
///
/// This is the Phase 9b default and acts as the always-available
/// fallback — the model is bundled inside the ML Kit plugin and needs
/// no download or tensor wiring. Target latency: 8-15 ms on a midrange
/// device.
class MediaPipeBgRemoval implements BgRemovalStrategy {
  MediaPipeBgRemoval({SelfieSegmenter? segmenter})
      : _segmenter = segmenter ??
            SelfieSegmenter(
              mode: SegmenterMode.single,
              enableRawSizeMask: true,
            );

  final SelfieSegmenter _segmenter;
  bool _closed = false;

  @override
  BgRemovalStrategyKind get kind => BgRemovalStrategyKind.mediaPipe;

  @override
  Future<ui.Image> removeBackgroundFromPath(String sourcePath) async {
    if (_closed) {
      _log.w('run rejected — session closed', {'path': sourcePath});
      throw const BgRemovalException(
        'MediaPipeBgRemoval is closed',
        kind: BgRemovalStrategyKind.mediaPipe,
      );
    }
    final sw = Stopwatch()..start();
    _log.i('run start', {'path': sourcePath});
    try {
      final inputImage = InputImage.fromFilePath(sourcePath);
      final segmentationMask = await _segmenter.processImage(inputImage);
      if (segmentationMask == null) {
        throw const BgRemovalException(
          'Segmenter returned no mask (no subject detected?)',
          kind: BgRemovalStrategyKind.mediaPipe,
        );
      }
      _log.d('mask received', {
        'width': segmentationMask.width,
        'height': segmentationMask.height,
        'confidences': segmentationMask.confidences.length,
      });

      final bytes = await File(sourcePath).readAsBytes();
      final sourceImage = await _decodeImage(bytes);
      _log.d('source decoded', {
        'width': sourceImage.width,
        'height': sourceImage.height,
      });

      final cutout = await _applyMaskAlpha(sourceImage, segmentationMask);
      sw.stop();
      _log.i('run complete', {
        'ms': sw.elapsedMilliseconds,
        'outputW': cutout.width,
        'outputH': cutout.height,
      });
      return cutout;
    } on BgRemovalException {
      rethrow;
    } catch (e, st) {
      sw.stop();
      _log.e('run failed',
          error: e, stackTrace: st, data: {'ms': sw.elapsedMilliseconds});
      throw BgRemovalException(
        e.toString(),
        kind: BgRemovalStrategyKind.mediaPipe,
      );
    }
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _log.i('close');
    await _segmenter.close();
  }

  // ----- internal helpers ---------------------------------------------------

  static Future<ui.Image> _decodeImage(Uint8List bytes) async {
    final codec = await ui.instantiateImageCodec(bytes);
    final frame = await codec.getNextFrame();
    codec.dispose();
    return frame.image;
  }

  /// Blend the MediaPipe confidence mask into the source image's alpha
  /// channel. Confidences are in `[0, 1]`; we map directly to alpha
  /// for a soft matte, which handles hair edges better than a binary
  /// threshold.
  ///
  /// Uses straight (non-premultiplied) RGBA to avoid colour distortion
  /// when punching the alpha channel with the segmentation mask.
  static Future<ui.Image> _applyMaskAlpha(
    ui.Image source,
    SegmentationMask mask,
  ) async {
    final byteData = await source.toByteData(
      format: ui.ImageByteFormat.rawStraightRgba,
    );
    if (byteData == null) {
      throw const BgRemovalException(
        'Failed to read source pixels',
        kind: BgRemovalStrategyKind.mediaPipe,
      );
    }
    final rgba = byteData.buffer.asUint8List();
    final width = source.width;
    final height = source.height;

    final maskW = mask.width;
    final maskH = mask.height;
    final confidences = mask.confidences;

    _log.d('mask vs source dims', {
      'maskW': maskW,
      'maskH': maskH,
      'srcW': width,
      'srcH': height,
    });

    final sw = Stopwatch()..start();
    for (int y = 0; y < height; y++) {
      // Map source row → mask row.
      final my = (maskH == height) ? y : ((y * maskH) ~/ height).clamp(0, maskH - 1);
      final maskRowOffset = my * maskW;
      final srcRowOffset = y * width;
      for (int x = 0; x < width; x++) {
        final mx = (maskW == width) ? x : ((x * maskW) ~/ width).clamp(0, maskW - 1);
        final c = confidences[maskRowOffset + mx];
        final a = (c * 255.0 + 0.5).toInt().clamp(0, 255);
        rgba[(srcRowOffset + x) * 4 + 3] = a;
      }
    }
    sw.stop();
    _log.d('mask composited', {'ms': sw.elapsedMilliseconds});

    // Re-upload as a ui.Image via decodeImageFromPixels.
    final completer = Completer<ui.Image>();
    ui.decodeImageFromPixels(
      rgba,
      width,
      height,
      ui.PixelFormat.rgba8888,
      completer.complete,
    );
    return completer.future;
  }
}
