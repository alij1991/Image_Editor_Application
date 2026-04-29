import 'preset.dart';

/// Strength classification for a preset.
///
/// Drives UI hints (a "Strong" badge on tiles) and the default intensity
/// when a preset is first applied — "strong" presets start at 80% so the
/// user has headroom to dial back without having to reach for the
/// slider. "Subtle" and "standard" presets start at 100%.
///
/// This is purely UI metadata — it is **not** serialised into the
/// preset JSON, so custom user presets always fall back to
/// [PresetStrength.standard].
enum PresetStrength {
  /// Minimal intervention (e.g. "Natural", "Original"). Always safe on
  /// any photo.
  subtle,

  /// The default. Designed to look good on well-shot photos at 100%.
  standard,

  /// A stylised look that intentionally pushes some parameters past the
  /// universally-safe ceilings (e.g. "Dramatic", "Noir", "Cyberpunk").
  /// Rendered with a visible badge so the user knows what they're
  /// picking.
  strong,
}

/// Side-table of strength classifications for every built-in preset.
/// Keyed by `preset.id`. Anything missing is treated as
/// [PresetStrength.standard].
class PresetMetadata {
  PresetMetadata._();

  static const Map<String, PresetStrength> _strengthById = {
    // Popular
    'builtin.none': PresetStrength.subtle,
    'builtin.natural': PresetStrength.subtle,
    'builtin.punch': PresetStrength.standard,
    'builtin.rich_hdr': PresetStrength.standard,
    'builtin.fade': PresetStrength.standard,
    'builtin.pastel': PresetStrength.standard,

    // Portrait
    'builtin.portrait_pop': PresetStrength.standard,
    'builtin.warm_sun': PresetStrength.standard,
    'builtin.warm_sunset': PresetStrength.standard,

    // Landscape
    'builtin.cinematic': PresetStrength.standard,
    'builtin.teal_orange': PresetStrength.standard,
    'builtin.moody': PresetStrength.strong,

    // Film
    'builtin.film_portra': PresetStrength.standard,
    'builtin.film_kodachrome': PresetStrength.standard,
    'builtin.vintage': PresetStrength.standard,
    'builtin.cool_film': PresetStrength.standard,
    'builtin.matte': PresetStrength.standard,
    'builtin.sepia': PresetStrength.strong,

    // Bold
    'builtin.dramatic': PresetStrength.strong,
    'builtin.cyberpunk': PresetStrength.strong,

    // B&W
    'builtin.mono': PresetStrength.standard,
    'builtin.noir': PresetStrength.strong,
    'builtin.sharp_bw': PresetStrength.strong,
    'builtin.bw_gold': PresetStrength.standard,
    'builtin.silver': PresetStrength.standard,
  };

  static PresetStrength strengthOf(Preset preset) {
    return _strengthById[preset.id] ?? PresetStrength.standard;
  }

  /// Default intensity (0.0 – 2.0) when the preset is first applied.
  static double defaultAmountOf(Preset preset) {
    return strengthOf(preset) == PresetStrength.strong ? 0.80 : 1.00;
  }

  /// Short human-readable label for a strength. Used by the UI badge.
  static String labelFor(PresetStrength s) => switch (s) {
        PresetStrength.subtle => 'Subtle',
        PresetStrength.standard => 'Standard',
        PresetStrength.strong => 'Strong',
      };
}
