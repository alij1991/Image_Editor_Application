import 'dart:ui' as ui;

/// Which background-removal pipeline the editor should run.
///
/// Phase 9b shipped only [mediaPipe]; Phase 9c adds [modnet] (TFLite)
/// and [rmbg] (ONNX). The picker sheet lets the user switch at
/// runtime, and the editor keeps a single strategy alive per session.
enum BgRemovalStrategyKind {
  /// Google ML Kit Selfie Segmentation. Bundled, portrait-focused,
  /// ~0.5 MB, 8-15 ms. Best for selfies + casual shots, not general.
  mediaPipe,

  /// MODNet portrait matting via TFLite. Downloaded (~7 MB). Higher
  /// quality edges on hair than MediaPipe, general portraits.
  modnet,

  /// RMBG-1.4 general matting via ONNX Runtime. Downloaded (~44 MB,
  /// int8 quantized). Highest quality, handles non-portrait subjects
  /// (animals, objects) at the cost of larger model + slower inference.
  ///
  /// Phase XVI.49: pairs the model with [ComposeEdgeRefine] post-
  /// processing (1.5 px feather + decontaminate) so the matte
  /// transition band looks closer to BiRefNet-tier output without
  /// requiring a second neural network.
  rmbg,

  /// VIII.12 — U²-Netp general matting via bundled TFLite (~5 MB).
  /// Offline alternative to [rmbg] for non-portrait subjects when the
  /// network is unavailable or the user wants to skip the 44 MB
  /// download. Lower quality on hair edges than RMBG but works on
  /// animals, objects, and any subject MediaPipe doesn't handle.
  generalOffline,

  /// Phase XV.1 — Robust Video Matting (MobileNetV3 fp32, ONNX).
  /// Downloaded (~15 MB). Best-in-class alpha on hair, fur, and
  /// motion-blurred edges — MODNet and RMBG both soften fine strands
  /// that RVM preserves because its recurrent architecture learned
  /// alpha from video sequences. Slower than MODNet (single 512 px
  /// forward pass is ~80 ms on A17 Pro CPU) but still interactive.
  rvm,

  /// Phase XVI.67 — BiRefNet-Lite (Zheng et al. 2024, github.com/
  /// ZhengPeng7/BiRefNet). Downloaded (~178 MB FP32). The "premium"
  /// tier — bilateral reference features push matte S_α from
  /// ~0.838 (RMBG-1.4) to ~0.872 on the DIS5K benchmark,
  /// dramatically better on long hair, fur, lace, jewellery, and
  /// other fine geometry that even RVM softens. Slowest of the
  /// downloadable matters but produces a noticeably crisper
  /// transition band, especially when paired with the XVI.66c
  /// native-resolution decode + upscale-scaled decontam.
  birefnetLite,
}

extension BgRemovalStrategyKindX on BgRemovalStrategyKind {
  /// User-facing label shown in the picker sheet.
  String get label {
    switch (this) {
      case BgRemovalStrategyKind.mediaPipe:
        return 'Fast (portrait)';
      case BgRemovalStrategyKind.modnet:
        return 'Balanced (portrait)';
      case BgRemovalStrategyKind.rmbg:
        return 'Best (any subject)';
      case BgRemovalStrategyKind.generalOffline:
        return 'Offline (any subject)';
      case BgRemovalStrategyKind.rvm:
        return 'Hair + fur (RVM)';
      case BgRemovalStrategyKind.birefnetLite:
        return 'Premium (BiRefNet-Lite)';
    }
  }

  /// Description shown below the label in the picker.
  String get description {
    switch (this) {
      case BgRemovalStrategyKind.mediaPipe:
        return 'Google ML Kit selfie segmentation. Bundled, ~10 ms. '
            'Best for selfies and clear portraits.';
      case BgRemovalStrategyKind.modnet:
        return 'MODNet neural matting. Downloaded (~7 MB). Better hair '
            'and edge detail than Fast.';
      case BgRemovalStrategyKind.rmbg:
        return 'RMBG-1.4 + edge refinement. Downloaded (~44 MB). Highest '
            'quality on hair, fur, and transparent subjects — slower.';
      case BgRemovalStrategyKind.generalOffline:
        return 'U²-Netp matting. Bundled (~5 MB). Works offline on any '
            'subject — lower edge quality than Best.';
      case BgRemovalStrategyKind.rvm:
        return 'Robust Video Matting. Downloaded (~15 MB). Best hair, fur, '
            'and motion-blur edges — slower than Balanced.';
      case BgRemovalStrategyKind.birefnetLite:
        return 'BiRefNet-Lite (Zheng 2024). Downloaded (~178 MB). The '
            'highest-quality matte the app offers — bilateral reference '
            'features capture long hair, lace, jewellery, and other fine '
            'geometry that every other tier softens. Slowest by ~2×.';
    }
  }

  /// The manifest model id this strategy needs at runtime. Returns
  /// null for strategies that don't depend on a downloadable model.
  String? get modelId {
    switch (this) {
      case BgRemovalStrategyKind.mediaPipe:
        return null; // bundled ML Kit, no manifest entry needed
      case BgRemovalStrategyKind.modnet:
        return 'modnet';
      case BgRemovalStrategyKind.rmbg:
        return 'rmbg_1_4_int8';
      case BgRemovalStrategyKind.generalOffline:
        return 'u2netp'; // bundled TFLite — the manifest entry is
                        // metadata-only; the file ships with the app.
      case BgRemovalStrategyKind.rvm:
        return 'rvm_mobilenetv3_fp32';
      case BgRemovalStrategyKind.birefnetLite:
        return 'birefnet_lite_fp32';
    }
  }

  /// True if this strategy relies on a downloadable model that may
  /// need a network fetch on first use.
  bool get isDownloadable {
    switch (this) {
      case BgRemovalStrategyKind.mediaPipe:
      case BgRemovalStrategyKind.generalOffline:
        return false;
      case BgRemovalStrategyKind.modnet:
      case BgRemovalStrategyKind.rmbg:
      case BgRemovalStrategyKind.rvm:
      case BgRemovalStrategyKind.birefnetLite:
        return true;
    }
  }

  /// Phase XVI.77 — whether the picker sheet should surface this
  /// strategy to the user at all. Filters at the iteration boundary
  /// in [BgRemovalPickerSheet]; all other plumbing (factory,
  /// availability checks, manifest entry, tests) stays intact so
  /// the deferred strategy keeps building.
  ///
  /// BiRefNet-Lite was added in XVI.67 + iteratively de-risked
  /// across XVI.68 → XVI.76. Every execution path we tried on iOS
  /// (CPU fp32, CPU fp16, CoreML+ANE with `enableOnSubgraph`) OOM'd
  /// on iPhone 15 Pro Max — even though that's the highest-RAM
  /// iPhone Apple ships (8 GB physical, 3376 MB per-app high
  /// watermark). The intermediate Swin attention maps at the model's
  /// hard-baked 1024×1024 input simply exceed what an iOS app can
  /// allocate. Hiding it from the picker prevents a guaranteed-crash
  /// tap; revival paths (re-export at 512, native Core ML conversion
  /// via coremltools, future iOS memory-budget increases) are
  /// documented in docs/model_audit_2026.md.
  bool get visibleInPicker {
    switch (this) {
      case BgRemovalStrategyKind.birefnetLite:
        return false;
      case BgRemovalStrategyKind.mediaPipe:
      case BgRemovalStrategyKind.modnet:
      case BgRemovalStrategyKind.rmbg:
      case BgRemovalStrategyKind.generalOffline:
      case BgRemovalStrategyKind.rvm:
        return true;
    }
  }
}

/// Abstract base class for every background-removal implementation.
///
/// Each concrete strategy owns its own model lifecycle (MediaPipe
/// segmenter, LiteRT session, or ORT session) and releases it on
/// [close]. The editor session calls [removeBackgroundFromPath] and
/// drops the result into an `AdjustmentLayer.cutoutImage`.
abstract class BgRemovalStrategy {
  BgRemovalStrategyKind get kind;

  /// Run background removal on the image at [sourcePath] and return a
  /// new `ui.Image` with the subject pixels preserved and the
  /// background alpha-punched to zero. Throws [BgRemovalException] on
  /// failure so the caller can show a typed error message.
  Future<ui.Image> removeBackgroundFromPath(String sourcePath);

  /// Release model handles + worker threads. Safe to call more than
  /// once.
  Future<void> close();
}

/// Typed exception for background-removal failures. Thrown by every
/// [BgRemovalStrategy] implementation + [BgRemovalStrategyFactory]
/// when inference, model loading, or download fails.
///
/// [cause] carries the original runtime exception (usually an
/// [MlRuntimeException] from the underlying runtime adapter) when
/// available, so error snackbars stay user-readable while logs keep
/// the deeper stack trace. `toString()` includes both.
class BgRemovalException implements Exception {
  const BgRemovalException(this.message, {this.kind, this.cause});

  final String message;

  /// The strategy that failed, if known. Null for factory-level
  /// errors (e.g. model not downloaded yet).
  final BgRemovalStrategyKind? kind;

  /// Underlying cause (e.g. an `MlRuntimeException`) if this
  /// exception was rewrapped at a higher layer. Preserved so the
  /// session-level logs can show the full failure chain.
  final Object? cause;

  @override
  String toString() {
    final prefix = kind == null
        ? 'BgRemovalException'
        : 'BgRemovalException[${kind!.name}]';
    final suffix = cause == null ? '' : ' (caused by $cause)';
    return '$prefix: $message$suffix';
  }
}
