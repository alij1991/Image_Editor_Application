import 'dart:typed_data';
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
  }) {
    return recolourMultipleFromPath(
      sourcePath: sourcePath,
      targets: [
        RecolourTarget(
          classes: classes,
          targetR: targetR,
          targetG: targetG,
          targetB: targetB,
        ),
      ],
    );
  }

  /// Phase XVI.47 — multi-target recolour in one inference.
  ///
  /// Pre-XVI.47 the recolour flow ran the segmenter once per target
  /// (one model run for hair, another for clothes). Since the
  /// multiclass model returns ALL six class scores in a single
  /// inference, we can batch any number of targets — hair to red,
  /// clothes to blue, accessories to green — for the price of one
  /// segmentation pass.
  ///
  /// The masks are derived from per-target class sets; argmax
  /// guarantees they're non-overlapping at segmentation resolution,
  /// so chaining the LAB-shift sequentially is correct (each pass
  /// only modifies pixels its own mask covers, leaving the prior
  /// pass's writes untouched).
  ///
  /// Returns a new `ui.Image` containing every requested shift.
  /// Throws [HairClothesRecolourException] when [targets] is empty
  /// or any per-target class set is empty.
  Future<ui.Image> recolourMultipleFromPath({
    required String sourcePath,
    required List<RecolourTarget> targets,
  }) async {
    if (_closed) {
      throw const HairClothesRecolourException('service is closed');
    }
    if (targets.isEmpty) {
      throw const HairClothesRecolourException(
        'targets list must not be empty',
      );
    }
    for (final t in targets) {
      if (t.classes.isEmpty) {
        throw const HairClothesRecolourException(
          'every target classes set must be non-empty',
        );
      }
    }
    final sw = Stopwatch()..start();

    final decoded = await BgRemovalImageIo.decodeFileToRgba(sourcePath);
    _log.d('decoded', {'w': decoded.width, 'h': decoded.height});

    // Single segmentation inference shared across all targets.
    final segResult = await segmentation.runOnRgba(
      sourceRgba: decoded.bytes,
      sourceWidth: decoded.width,
      sourceHeight: decoded.height,
    );

    // Apply each target's LAB shift sequentially. The `working` buffer
    // threads through — each shift starts from the previous one's
    // output so multiple recolours stack into the final image.
    Uint8List working = decoded.bytes;
    for (final target in targets) {
      final smallMask = segResult.maskForClasses(target.classes);
      final bigMask = SelfieMulticlassResult.bilinearResize(
        src: smallMask,
        srcWidth: segResult.width,
        srcHeight: segResult.height,
        dstWidth: decoded.width,
        dstHeight: decoded.height,
      );
      working = RgbOps.shiftLabAbForMaskedPixels(
        source: working,
        width: decoded.width,
        height: decoded.height,
        mask: bigMask,
        targetR: target.targetR,
        targetG: target.targetG,
        targetB: target.targetB,
        strength: strength,
      );
    }

    final image = await BgRemovalImageIo.encodeRgbaToUiImage(
      rgba: working,
      width: decoded.width,
      height: decoded.height,
    );
    sw.stop();
    _log.i('recolour complete', {
      'ms': sw.elapsedMilliseconds,
      'targets': targets.length,
      'classes': targets.map((t) => t.classes.toList()).toList(),
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

/// Phase XVI.47 — single recolour target. A list of these drives the
/// multi-target [HairClothesRecolourService.recolourMultipleFromPath]
/// flow. Each target picks a class set (`{1}` = hair, `{4}` = clothes,
/// `{5}` = accessories, or unions thereof) and a target sRGB colour.
class RecolourTarget {
  const RecolourTarget({
    required this.classes,
    required this.targetR,
    required this.targetG,
    required this.targetB,
  });

  /// Selfie-multiclass class indices to mask for this target.
  final Set<int> classes;

  /// Target sRGB colour, 0–255 per channel.
  final int targetR;
  final int targetG;
  final int targetB;
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
