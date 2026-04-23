import 'dart:ui' as ui;

import '../../../core/logging/app_logger.dart';
import '../../inference/rgb_ops.dart';
import '../bg_removal/image_io.dart';
import 'selfie_multiclass_service.dart';

final _log = AppLogger('HairClothesRecolourService');

/// Phase XV.2: composite recolour action that runs
/// [SelfieMulticlassService], builds a mask from the requested class
/// set, and blends a target sRGB colour into the image via a
/// luminance-preserving LAB a*/b* shift.
///
/// The service owns its segmentation session — [close] releases it.
class HairClothesRecolourService {
  HairClothesRecolourService({
    required this.segmentation,
    this.strength = 0.8,
  });

  /// The selfie-multiclass segmenter the service drives. Ownership
  /// transfers to the service; [close] releases the LiteRT session.
  final SelfieMulticlassService segmentation;

  /// Overall blend strength passed through to
  /// [RgbOps.shiftLabAbForMaskedPixels]. 1.0 = fully replace a*/b*,
  /// 0.0 = no-op. 0.8 looks natural for most hair / clothing tints.
  final double strength;

  bool _closed = false;

  /// Run the full recolour pipeline on a file on disk.
  ///
  /// - [sourcePath]: the image file.
  /// - [classes]: set of selfie-multiclass class indices to recolour.
  ///   Typical picks: `{1}` (hair), `{4}` (clothes),
  ///   `{1, 5}` (hair + accessories).
  /// - [targetR], [targetG], [targetB]: target sRGB colour in 0..255.
  ///
  /// Returns a new `ui.Image` the caller drops into an
  /// `AdjustmentLayer(adjustmentKind: hairClothesRecolour)`.
  Future<ui.Image> recolourFromPath({
    required String sourcePath,
    required Set<int> classes,
    required int targetR,
    required int targetG,
    required int targetB,
  }) async {
    if (_closed) {
      throw const HairClothesRecolourException('service is closed');
    }
    if (classes.isEmpty) {
      throw const HairClothesRecolourException('classes set must not be empty');
    }
    final sw = Stopwatch()..start();

    final decoded = await BgRemovalImageIo.decodeFileToRgba(sourcePath);
    _log.d('decoded', {'w': decoded.width, 'h': decoded.height});

    final segResult = await segmentation.runOnRgba(
      sourceRgba: decoded.bytes,
      sourceWidth: decoded.width,
      sourceHeight: decoded.height,
    );

    // Build the per-class mask at segmentation resolution and
    // bilinearly upscale to source resolution. Bilinear upsample
    // handles edge feathering — the hard 0/1 argmax becomes a
    // smooth 0..1 ramp across class boundaries.
    final smallMask = segResult.maskForClasses(classes);
    final bigMask = SelfieMulticlassResult.bilinearResize(
      src: smallMask,
      srcWidth: segResult.width,
      srcHeight: segResult.height,
      dstWidth: decoded.width,
      dstHeight: decoded.height,
    );

    final recoloured = RgbOps.shiftLabAbForMaskedPixels(
      source: decoded.bytes,
      width: decoded.width,
      height: decoded.height,
      mask: bigMask,
      targetR: targetR,
      targetG: targetG,
      targetB: targetB,
      strength: strength,
    );

    final image = await BgRemovalImageIo.encodeRgbaToUiImage(
      rgba: recoloured,
      width: decoded.width,
      height: decoded.height,
    );
    sw.stop();
    _log.i('recolour complete', {
      'ms': sw.elapsedMilliseconds,
      'classes': classes.toList(),
    });
    return image;
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    try {
      await segmentation.close();
    } catch (e, st) {
      _log.e('segmentation close failed', error: e, stackTrace: st);
    }
  }
}

class HairClothesRecolourException implements Exception {
  const HairClothesRecolourException(this.message, {this.cause});
  final String message;
  final Object? cause;

  @override
  String toString() {
    if (cause == null) return 'HairClothesRecolourException: $message';
    return 'HairClothesRecolourException: $message (caused by $cause)';
  }
}
