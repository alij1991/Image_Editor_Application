import '../../core/logging/app_logger.dart';
import '../pipeline/edit_op_type.dart';
import '../pipeline/edit_operation.dart';
import '../pipeline/edit_pipeline.dart';
import 'preset.dart';

final _log = AppLogger('PresetApplier');

/// Whether applying a preset should clear out unrelated color / effect ops
/// first (`reset`, the Lightroom default for built-in looks) or leave them
/// in place and only overwrite the ops mentioned by the preset (`merge`,
/// useful for stacking small custom recipes).
enum PresetPolicy { reset, merge }

/// Applies a [Preset]'s operations to an [EditPipeline].
///
/// Two policies:
///
/// - [PresetPolicy.reset] — first strips every op listed in
///   [EditOpType.presetReplaceable] (color / tone / filter / effect /
///   blur / noise) from the base pipeline, then appends the preset's
///   ops. Geometry, layers, masks, and AI adjustment-layers survive.
///   This prevents stale settings from a previous look (e.g. a `tint`
///   slider drag) bleeding into a new preset and producing surprises
///   like a green-tinted "Noir".
///
/// - [PresetPolicy.merge] — original behaviour: replace ops by type,
///   append the rest. Useful for layering custom mini-presets.
///
/// Applying a preset with no operations is a no-op in both modes.
class PresetApplier {
  const PresetApplier();

  EditPipeline apply(
    Preset preset,
    EditPipeline base, {
    PresetPolicy policy = PresetPolicy.reset,
  }) {
    _log.i('apply', {
      'preset': preset.name,
      'policy': policy.name,
      'opsInPreset': preset.operations.length,
      'opsInBase': base.operations.length,
    });
    if (preset.operations.isEmpty) return base;

    var next = base;
    if (policy == PresetPolicy.reset) {
      final survivors = base.operations
          .where((o) => !EditOpType.presetReplaceable.contains(o.type))
          .toList();
      next = base.copyWith(operations: survivors);
      for (final presetOp in preset.operations) {
        next = next.append(
          EditOperation.create(
            type: presetOp.type,
            parameters: Map.of(presetOp.parameters),
          ),
        );
      }
      return next;
    }

    for (final presetOp in preset.operations) {
      final existing = next.operations.where((o) => o.type == presetOp.type);
      if (existing.isNotEmpty) {
        // Keep the existing op id (so slider thumbs follow the change
        // via the id cache) AND the enabled flag (so applying a preset
        // doesn't un-disable ops the user intentionally turned off).
        final replaced = existing.first.copyWith(
          parameters: Map.of(presetOp.parameters),
        );
        next = next.replace(replaced);
      } else {
        next = next.append(
          EditOperation.create(
            type: presetOp.type,
            parameters: Map.of(presetOp.parameters),
          ),
        );
      }
    }
    return next;
  }
}
