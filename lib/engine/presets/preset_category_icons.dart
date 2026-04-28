import 'package:flutter/material.dart';

/// Phase XVI.62 — taxonomy + icons for the preset category rail.
///
/// The category rail in `preset_strip.dart` was rendering text-only
/// chips. Adding a leading icon per category gives the rail more
/// visual weight at a glance and matches the iconography Lightroom /
/// Pixelmator have used since 2023. Lives outside the [Preset]
/// freezed class so the codegen surface stays untouched (no
/// build_runner regen needed); the rail UI looks up icons by category
/// id via [presetCategoryIconFor].
///
/// Adding a new category:
///   1. Add the canonical id to `BuiltInPresets.categories`.
///   2. Add a labelFor entry in `built_in_presets.dart`.
///   3. Add an icon mapping below.
///   4. The consistency test in
///      `test/engine/presets/preset_category_icons_test.dart` will
///      fail until all three lists agree — that's the contract.
class PresetCategoryInfo {
  const PresetCategoryInfo({
    required this.id,
    required this.label,
    required this.icon,
  });

  /// Stable id used by [Preset.category] and persisted in JSON.
  final String id;

  /// User-facing label rendered next to the icon in the chip.
  final String label;

  /// Material icon rendered to the left of the label.
  final IconData icon;
}

/// Canonical taxonomy of built-in preset categories. Order matters —
/// the rail renders entries left-to-right in this sequence after the
/// implicit "All" chip. New categories should be appended; reordering
/// shifts the rail's visual rhythm so any reorder lands as its own
/// commit with screenshot review.
const List<PresetCategoryInfo> presetCategoryTaxonomy = [
  PresetCategoryInfo(id: 'popular', label: 'Popular', icon: Icons.star),
  PresetCategoryInfo(id: 'portrait', label: 'Portrait', icon: Icons.face),
  PresetCategoryInfo(
      id: 'landscape', label: 'Landscape', icon: Icons.landscape),
  PresetCategoryInfo(id: 'film', label: 'Film', icon: Icons.theaters),
  PresetCategoryInfo(id: 'bw', label: 'B&W', icon: Icons.contrast),
  PresetCategoryInfo(
      id: 'bold', label: 'Bold', icon: Icons.local_fire_department),
];

/// Look up the icon for a category id. Returns a generic palette icon
/// for unknown categories (e.g. user-saved presets in a future phase
/// that introduces custom categories) so the rail still renders
/// something visible instead of an empty leading slot.
IconData presetCategoryIconFor(String id) {
  for (final c in presetCategoryTaxonomy) {
    if (c.id == id) return c.icon;
  }
  return Icons.palette;
}

/// Look up the human-readable label. Falls back to the id verbatim so
/// custom categories still render text in the rail.
String presetCategoryLabelFor(String id) {
  for (final c in presetCategoryTaxonomy) {
    if (c.id == id) return c.label;
  }
  return id;
}
