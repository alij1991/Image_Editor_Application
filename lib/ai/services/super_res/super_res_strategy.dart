import 'dart:ui' as ui;

/// Phase XVI.53 — strategy interface for the super-resolution flow.
///
/// Pre-XVI.53 the editor used a single concrete `SuperResService`
/// (Real-ESRGAN-x4plus, ~67 MB). The plan calls for an x2 default
/// (~17 MB, ~4× faster) with the x4 path kept as an opt-in
/// "warning, slow" tier. Both implementations share the same
/// I/O contract — input image → upscaled image — so the editor
/// talks to this interface and the picker decides which to spin up.
///
/// Mirrors `BgRemovalStrategy` and `InpaintStrategy` (XVI.51): an
/// interface lets the AI coordinator commit to a single API while
/// the picker chooses the concrete strategy at runtime.
abstract class SuperResStrategy {
  /// Which concrete strategy this is. Lets the call site
  /// distinguish x2 vs x4 for telemetry / diagnostic logs.
  SuperResStrategyKind get kind;

  /// Scale factor (e.g. 2 for x2, 4 for x4). Drives the latency
  /// warning copy + the post-processing crop math.
  int get scaleFactor;

  /// Run super-resolution on the image at [sourcePath]. Returns a
  /// `ui.Image` at `scaleFactor` × the source preview-dimensions.
  Future<ui.Image> enhanceFromPath(String sourcePath);

  /// Release model handles + worker threads. Safe to call more than
  /// once.
  Future<void> close();
}

/// Which super-resolution model is currently driving the strategy.
///
/// Default-recommended is x2 (smaller, faster, and the perceptual
/// lift on phone-sized output is comparable to x4 once the screen
/// downsamples back to its native resolution). x4 remains for
/// power users who export at the full upscaled resolution.
enum SuperResStrategyKind {
  /// Real-ESRGAN-x2plus (community ONNX export). ~17 MB FP16.
  /// Doubles input dimensions; ~50 ms per call at 256×256 → 512×512
  /// on phone CPUs. Phase XVI.53 default.
  x2,

  /// Real-ESRGAN-x4plus (Qualcomm TFLite export). ~67 MB FP32.
  /// Quadruples input dimensions; ~200 ms per call at 256×256 →
  /// 1024×1024. Pre-XVI.53 was the only super-res option; now
  /// kept as a power-user toggle with a latency warning.
  x4,
}

extension SuperResStrategyKindX on SuperResStrategyKind {
  /// User-facing label shown in the picker sheet.
  String get label {
    switch (this) {
      case SuperResStrategyKind.x2:
        return 'Enhance 2× (Fast)';
      case SuperResStrategyKind.x4:
        return 'Enhance 4× (Slow)';
    }
  }

  /// Description shown below the label.
  String get description {
    switch (this) {
      case SuperResStrategyKind.x2:
        return 'Real-ESRGAN-x2. Downloaded (~17 MB). Doubles '
            'resolution — fast and lifts most detail you\'ll see on '
            'screen.';
      case SuperResStrategyKind.x4:
        return 'Real-ESRGAN-x4. Downloaded (~67 MB). Quadruples '
            'resolution — slower (~4×) and only worth it if you '
            'export at the full upscaled size.';
    }
  }

  /// Manifest model id this strategy needs at runtime.
  String get modelId {
    switch (this) {
      case SuperResStrategyKind.x2:
        return 'real_esrgan_x2_fp16';
      case SuperResStrategyKind.x4:
        return 'real_esrgan_x4';
    }
  }

  /// Linear scale factor (2 or 4).
  int get scaleFactor {
    switch (this) {
      case SuperResStrategyKind.x2:
        return 2;
      case SuperResStrategyKind.x4:
        return 4;
    }
  }
}

/// Typed exception for super-resolution failures. Both x2 and x4
/// strategies throw this so the AI coordinator's `applyEnhance` flow
/// can `rethrowTyped` against a single exception class regardless of
/// which model ran.
///
/// Pre-XVI.53 lived in `super_res_service.dart` (the x4 service).
/// Lifted here so the strategy interface stays self-contained.
class SuperResException implements Exception {
  const SuperResException(this.message, {this.kind, this.cause});

  final String message;

  /// The strategy that failed, if known.
  final SuperResStrategyKind? kind;

  /// Underlying cause (e.g. an `MlRuntimeException`) when this
  /// exception was rewrapped at a higher layer.
  final Object? cause;

  @override
  String toString() {
    final prefix = kind == null
        ? 'SuperResException'
        : 'SuperResException[${kind!.name}]';
    final suffix = cause == null ? '' : ' (caused by $cause)';
    return '$prefix: $message$suffix';
  }
}
