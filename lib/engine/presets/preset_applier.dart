import '../../core/logging/app_logger.dart';
import '../pipeline/edit_operation.dart';
import '../pipeline/edit_pipeline.dart';
import 'preset.dart';
import 'preset_intensity.dart';

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
///
/// Per-preset intensity (Lightroom Mobile "Amount" / VSCO "Strength")
/// is supported via the [amount] parameter — see [PresetIntensity] for
/// the blending maths. `amount` defaults to 1.0 which reproduces the
/// preset exactly. At `amount = 0` no preset ops are appended
/// (equivalent to applying Original).
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

  /// Returns true if [op] would be wiped by a preset application.
  /// Exposed so callers (e.g. the editor session baseline snapshot)
  /// can decide which ops fall under a preset's domain.
  static bool ownedByPreset(EditOperation op) =>
      _presetOwnedPrefixes.any((p) => op.type.startsWith(p));

  /// Apply [preset] to [base] at a given [amount] (0.0–1.5). At
  /// `amount == 1.0` (the default) this reproduces the preset's
  /// designed look. Lower values interpolate back toward the unedited
  /// photo; higher values extrapolate past the preset (clamped per-op
  /// to the registered slider range).
  EditPipeline apply(Preset preset, EditPipeline base, {double amount = 1.0}) {
    _log.i('apply', {
      'preset': preset.name,
      'opsInPreset': preset.operations.length,
      'opsInBase': base.operations.length,
      'amount': amount.toStringAsFixed(2),
    });

    // 1. Drop every existing op that a preset is allowed to set.
    //    Geometry, layers and AI ops pass through untouched.
    var next = base;
    final toDrop = next.operations
        .where(ownedByPreset)
        .map((op) => op.id)
        .toList(growable: false);
    for (final id in toDrop) {
      next = next.remove(id);
    }
    if (toDrop.isNotEmpty) {
      _log.d('cleared preset-owned ops', {'count': toDrop.length});
    }

    // 2. Blend the preset's ops at the requested amount and append.
    //    At amount == 0 the blend returns [], so the pipeline ends up
    //    as just the geometry / layer / AI carryover — same outcome
    //    as applying the "Original" preset.
    const intensity = PresetIntensity();
    final blended = intensity.blend(preset, amount);
    for (final op in blended) {
      next = next.append(op);
    }
    _log.d('appended blended ops', {'count': blended.length});
    return next;
  }
}
