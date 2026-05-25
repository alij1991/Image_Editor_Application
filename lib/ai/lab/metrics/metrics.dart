/// XVI.95a — Barrel export for the AI Test Lab metric library.
///
/// Pure-Dart, no Flutter / dart:ui dependencies. Runs in
/// `flutter test` (Tier 1) AND on-device under `/dev/ai-test-lab`
/// (Tier 2). All metrics are deterministic so two runs on the same
/// input produce bit-identical results — the lab's baseline diff
/// relies on that.
library;

export 'boundary_iou.dart';
export 'laplacian_variance.dart';
export 'mask_iou.dart';
export 'matting_metrics.dart';
export 'metric_result.dart';
export 'psnr.dart';
export 'ssim.dart';
