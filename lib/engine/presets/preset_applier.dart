import '../../core/logging/app_logger.dart';
import '../pipeline/edit_operation.dart';
import '../pipeline/edit_pipeline.dart';
import 'preset.dart';

final _log = AppLogger('PresetApplier');

/// Merges a [Preset]'s operations into an [EditPipeline].
///
/// Strategy: **replace-the-look**. Applying a preset wipes every
/// existing colour / tone / effect / filter / blur / noise op, then
/// appends the preset's ops fresh. Geometry (crop / rotate / flip /
/// straighten / perspective), layers (text / stickers / drawings) and
/// AI-generated cutouts all survive untouched.
///
/// This matches Snapseed / Instagram / Apple Photos filter semantics
/// where tapping a new filter completely replaces the previous filter
/// rather than compounding on top of it. The previous "leave panels
/// untouched" behaviour caused visible artefacts when stacking presets
/// (e.g. Pastel after Portrait Pop kept Portrait Pop's vibrance boost
/// on top of Pastel's desaturation, producing unnatural colours).
///
/// Applying the 'Original' preset (empty operations) clears every
/// colour/tone/effect op → returns the photo to its untouched state
/// while keeping any geometry / layers the user had placed.
class PresetApplier {
  const PresetApplier();

  /// Type prefixes that a preset owns. Any op whose type starts with
  /// one of these is wiped before the new preset's ops are appended.
  /// The remaining categories (geom.*, layer.*, ai.*) are orthogonal
  /// to a filter/look preset and survive.
  static const List<String> _presetOwnedPrefixes = [
    'color.',
    'fx.',
    'filter.',
    'blur.',
    'noise.',
  ];

  EditPipeline apply(Preset preset, EditPipeline base) {
    _log.i('apply', {
      'preset': preset.name,
      'opsInPreset': preset.operations.length,
      'opsInBase': base.operations.length,
    });

    // 1. Drop every existing op that a preset is allowed to set.
    //    Geometry, layers and AI ops pass through untouched.
    var next = base;
    final toDrop = next.operations
        .where((op) =>
            _presetOwnedPrefixes.any((p) => op.type.startsWith(p)))
        .map((op) => op.id)
        .toList(growable: false);
    for (final id in toDrop) {
      next = next.remove(id);
    }
    if (toDrop.isNotEmpty) {
      _log.d('cleared preset-owned ops', {'count': toDrop.length});
    }

    // 2. Append the new preset's ops fresh (each with a new uuid so
    //    undo/history sees them as distinct entries).
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
}
