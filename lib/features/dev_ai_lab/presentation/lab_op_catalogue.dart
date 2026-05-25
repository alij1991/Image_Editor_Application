/// XVI.97 (B3) — Catalogue of AI ops the lab can validate.
///
/// Decoupled from the actual service implementations so the lab UI
/// can render the picker before the per-op runners (B4) are wired.
/// Each entry declares:
///   - [id] — stable string used in manifests, commit-message
///     trailers, and the corpus's `expectedOps` field.
///   - [label] / [description] — human-readable text for the picker.
///   - [primaryMetric] — short name of the lead metric shown next to
///     the op in the picker (e.g. `"SSIM"`, `"BoundaryIoU"`).
///   - [requiresGroundTruth] — true when the op can only run on
///     images that ship a matching ground-truth asset.
library;

import 'package:flutter/foundation.dart';

@immutable
class LabOp {
  const LabOp({
    required this.id,
    required this.label,
    required this.description,
    required this.primaryMetric,
    required this.requiresGroundTruth,
  });

  final String id;
  final String label;
  final String description;
  final String primaryMetric;
  final bool requiresGroundTruth;
}

/// Canonical catalogue. Ordering reflects roughly the audit-doc
/// priority (the ops that have failed device tests come first).
const List<LabOp> kLabOps = [
  LabOp(
    id: 'sky_replace',
    label: 'Sky Replace',
    description: 'XVI.93a regression scene — mask must NOT bleed into '
        'trees / flowers below the horizon.',
    primaryMetric: 'sky_mask_iou',
    requiresGroundTruth: true,
  ),
  LabOp(
    id: 'reduce_noise_identity',
    label: 'Reduce Noise (clean input)',
    description: 'Reduce-Noise on a clean image must NOT soften it. '
        'SSIM vs input >= 0.96.',
    primaryMetric: 'SSIM',
    requiresGroundTruth: false,
  ),
  LabOp(
    id: 'reduce_noise_recovery',
    label: 'Reduce Noise (noisy input)',
    description: 'Reduce-Noise on a noisy image should recover '
        '~30 dB PSNR vs the clean reference.',
    primaryMetric: 'PSNR',
    requiresGroundTruth: true,
  ),
  LabOp(
    id: 'deblur_identity',
    label: 'AI Deblur (sharp input)',
    description: 'AI Deblur on a sharp image must NOT soften it. '
        'ΔLaplacianVar >= 0.',
    primaryMetric: 'LapVar Δ',
    requiresGroundTruth: false,
  ),
  LabOp(
    id: 'deblur_recovery',
    label: 'AI Deblur (blurred input)',
    description: 'AI Deblur on a blurred image should raise Laplacian '
        'variance ≥ 1.3×.',
    primaryMetric: 'LapVar Δ',
    requiresGroundTruth: false,
  ),
  LabOp(
    id: 'bg_removal',
    label: 'Background Removal',
    description: 'Every BG-removal tier (RMBG / MODNet / RVM / U²-Netp / '
        'SelfieSegmenter). IoU >= 0.85, Boundary IoU >= 0.70.',
    primaryMetric: 'BoundaryIoU',
    requiresGroundTruth: true,
  ),
  LabOp(
    id: 'smart_crop',
    label: 'Smart Crop',
    description: 'Crop must contain 100 % of subject bbox and area '
        '≤ 1.3× subject. Validates the XVI.91 race-fix.',
    primaryMetric: 'bbox_containment',
    requiresGroundTruth: true,
  ),
  LabOp(
    id: 'mobile_sam_tap',
    label: 'MobileSAM tap-to-segment',
    description: 'One tap → one mask. IoU vs hand-painted target '
        '>= 0.80 per tap.',
    primaryMetric: 'MaskIoU',
    requiresGroundTruth: true,
  ),
  LabOp(
    id: 'inpaint',
    label: 'Inpaint',
    description: 'LaMa / MI-GAN: no visible seam, LPIPS in mask ≤ 0.30.',
    primaryMetric: 'edge_consistency',
    requiresGroundTruth: true,
  ),
  LabOp(
    id: 'face_restore',
    label: 'Face Restore (CodeFormer)',
    description: '512² per-face crop. LPIPS vs input within face crop '
        '≤ 0.25.',
    primaryMetric: 'LPIPS',
    requiresGroundTruth: false,
  ),
  LabOp(
    id: 'compose_on_bg',
    label: 'Compose on Background',
    description: 'Harmoniser: ΔLab mean ≤ 5, ΔLab std ≤ 3 vs target '
        'colour stats.',
    primaryMetric: 'ΔLab',
    requiresGroundTruth: false,
  ),
];

/// Look up a [LabOp] by id. Returns null when missing rather than
/// throwing — the UI handles unknown ids gracefully (lab corpus
/// declares `expectedOps` that may eventually go stale).
LabOp? labOpById(String id) {
  for (final op in kLabOps) {
    if (op.id == id) return op;
  }
  return null;
}
