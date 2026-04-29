import 'dart:typed_data';
import 'dart:ui' as ui;

/// Phase XVI.51 — strategy interface for the inpaint flow.
///
/// Pre-XVI.51 the editor used a single concrete `InpaintService`
/// (LaMa). The plan calls for MI-GAN as the mobile-grade alternative
/// (~30 MB vs LaMa's ~210 MB, ~50 ms vs ~200 ms at 512×512). Both
/// implementations share the same I/O contract, so the editor talks
/// to this interface and the picker decides which to instantiate.
///
/// The pattern mirrors `BgRemovalStrategy` — interface lets the AI
/// coordinator commit to an interface type while the user picks the
/// concrete strategy at runtime via a model picker sheet.
abstract class InpaintStrategy {
  /// Which concrete strategy this is. Lets the call site distinguish
  /// LaMa vs MI-GAN for telemetry / diagnostic logs.
  InpaintStrategyKind get kind;

  /// Run inpainting on the image at [sourcePath] using [maskRgba]
  /// (an RGBA buffer of size [maskWidth] × [maskHeight] where R ≥ 128
  /// marks the region to fill). Returns a `ui.Image` at preview-
  /// quality resolution with the mask region filled in.
  Future<ui.Image> inpaintFromPath(
    String sourcePath, {
    required Uint8List maskRgba,
    required int maskWidth,
    required int maskHeight,
  });

  /// Release model handles + worker threads. Safe to call more than
  /// once.
  Future<void> close();
}

/// Which inpainting model is currently driving the strategy.
///
/// Matches the bg-removal pattern: an enum the picker shows + a
/// `modelId` getter the factory uses to resolve the manifest entry.
enum InpaintStrategyKind {
  /// LaMa (Resolution-robust Large Mask Inpainting). Quality-first
  /// option. ~210 MB FP32 ONNX, ~200 ms per call at 512×512 on
  /// phone CPUs. Pre-XVI.51 was the only inpaint strategy.
  lama,

  /// MI-GAN (Sargsyan et al. 2023, ECCV — Picsart). Mobile-tuned
  /// inpainting via knowledge distillation + co-modulation. ~30 MB
  /// FP32 ONNX, ~50 ms per call at 512×512 on phone CPUs.
  /// Comparable PSNR to LaMa on the standard inpainting benchmarks
  /// at a fraction of the latency / install cost.
  migan,
}

extension InpaintStrategyKindX on InpaintStrategyKind {
  /// User-facing label shown in the picker sheet.
  String get label {
    switch (this) {
      case InpaintStrategyKind.lama:
        return 'Quality (LaMa)';
      case InpaintStrategyKind.migan:
        return 'Fast (MI-GAN)';
    }
  }

  /// Description shown below the label in the picker.
  String get description {
    switch (this) {
      case InpaintStrategyKind.lama:
        return 'LaMa large-mask inpainting. Downloaded (~210 MB). '
            'Highest quality on big strokes — ~200 ms per call.';
      case InpaintStrategyKind.migan:
        return 'MI-GAN mobile inpainting. Downloaded (~30 MB). '
            'Comparable quality on small/medium strokes — ~50 ms per call.';
    }
  }

  /// The manifest model id this strategy needs at runtime.
  String get modelId {
    switch (this) {
      case InpaintStrategyKind.lama:
        return 'lama_inpaint';
      case InpaintStrategyKind.migan:
        return 'migan_512_fp32';
    }
  }
}

/// Typed exception for inpainting failures. Both [LaMa] and
/// [MI-GAN] strategies throw this so the AI coordinator's
/// `applyInpainting` flow can `rethrowTyped` against a single
/// exception class regardless of which model ran.
///
/// Pre-XVI.51 lived in `inpaint_service.dart` (the LaMa service file).
/// Lifted here so the strategy interface stays self-contained.
class InpaintException implements Exception {
  const InpaintException(this.message, {this.kind, this.cause});

  final String message;

  /// The strategy that failed, if known. Null for factory-level
  /// errors.
  final InpaintStrategyKind? kind;

  /// Underlying cause (e.g. an `MlRuntimeException`) when this
  /// exception was rewrapped at a higher layer.
  final Object? cause;

  @override
  String toString() {
    final prefix = kind == null
        ? 'InpaintException'
        : 'InpaintException[${kind!.name}]';
    final suffix = cause == null ? '' : ' (caused by $cause)';
    return '$prefix: $message$suffix';
  }
}
