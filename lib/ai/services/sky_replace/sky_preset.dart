/// Preset palettes for Phase 9g's sky replacement service.
///
/// Each preset is a procedural gradient generator — not a bundled
/// JPEG — because the editor has no real sky library yet and
/// shipping a palette of ~10 curated high-res JPEGs would bloat
/// the app binary without a clear win for users. The gradients
/// reproduce the defining color characteristics of common sky
/// moods (clear blue, sunset, night, dramatic overcast) and
/// composite cleanly through the heuristic sky mask.
///
/// Swapping in real JPEG-backed presets later is a one-method
/// change: the preset knows how to produce RGBA bytes at any
/// target resolution, so a future "load from asset + tile" variant
/// slots in behind the same enum without touching the service or
/// the picker UI.
enum SkyPreset {
  clearBlue,
  sunset,
  night,
  dramatic,
}

extension SkyPresetX on SkyPreset {
  /// User-facing label shown in the picker sheet.
  String get label {
    switch (this) {
      case SkyPreset.clearBlue:
        return 'Clear blue';
      case SkyPreset.sunset:
        return 'Sunset';
      case SkyPreset.night:
        return 'Night';
      case SkyPreset.dramatic:
        return 'Dramatic';
    }
  }

  /// Short description for the picker card.
  String get description {
    switch (this) {
      case SkyPreset.clearBlue:
        return 'Bright, cloudless daylight sky.';
      case SkyPreset.sunset:
        return 'Warm orange-to-violet gradient.';
      case SkyPreset.night:
        return 'Deep navy with a starry tint.';
      case SkyPreset.dramatic:
        return 'Moody overcast with cloud texture.';
    }
  }

  /// Canonical name used in the persisted pipeline JSON. Kept in
  /// sync with [SkyPreset.name] so `fromName` can round-trip.
  String get persistKey => name;

  static SkyPreset fromName(String? name) {
    if (name == null) return SkyPreset.clearBlue;
    for (final p in SkyPreset.values) {
      if (p.persistKey == name) return p;
    }
    return SkyPreset.clearBlue;
  }
}
