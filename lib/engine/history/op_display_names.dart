import '../pipeline/edit_op_type.dart';
import '../pipeline/op_spec.dart';

/// Phase X.A.1 — display-name lookup for op type strings.
///
/// Drives the undo/redo button tooltips + the `UserFeedback` snackbar
/// after undo/redo (e.g. "Undo Brightness", "Undone — Brightness").
/// Without this, the UI would either show raw op-type identifiers
/// (`color.brightness`) or no context at all.
///
/// Resolution order:
///   1. Slider ops — `OpSpecs.byType(type).label` (e.g. "Brightness")
///   2. Non-slider ops (crop, drawing, AI, etc.) — hand-rolled labels
///      below. These aren't registered in `OpSpecs` because they have
///      no parametric slider.
///   3. Fallback — the last dotted segment, capitalised.
///
/// Returns `null` only when [type] itself is null.
String? opDisplayLabel(String? type) {
  if (type == null) return null;
  final spec = OpSpecs.byType(type);
  if (spec != null) return spec.label;
  switch (type) {
    case EditOpType.crop:
      return 'Crop';
    case EditOpType.rotate:
      return 'Rotate';
    case EditOpType.flip:
      return 'Flip';
    case EditOpType.straighten:
      return 'Straighten';
    case EditOpType.perspective:
      return 'Perspective';
    case EditOpType.guidedUpright:
      return 'Guided Upright';
    case EditOpType.lensDistortion:
      return 'Lens correction';
    case EditOpType.text:
      return 'Text layer';
    case EditOpType.sticker:
      return 'Sticker';
    case EditOpType.drawing:
      return 'Drawing';
    case EditOpType.adjustmentLayer:
      return 'Adjustment';
    case EditOpType.aiBackgroundRemoval:
      return 'Remove background';
    case EditOpType.aiInpaint:
      return 'Inpaint';
    case EditOpType.aiSuperResolution:
      return 'Super-resolution';
    case EditOpType.aiStyleTransfer:
      return 'Style transfer';
    case EditOpType.aiFaceBeautify:
      return 'Beautify';
    case EditOpType.aiSkyReplace:
      return 'Replace sky';
    case EditOpType.lut3d:
      return 'LUT';
    case EditOpType.matrixPreset:
      return 'Preset';
    case 'preset.apply':
      return 'Preset';
  }
  final last = type.split('.').last;
  if (last.isEmpty) return null;
  return last[0].toUpperCase() + last.substring(1);
}
