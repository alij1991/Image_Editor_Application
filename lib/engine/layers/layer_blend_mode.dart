import 'dart:ui' show BlendMode;

/// Per-layer blend mode. Phase 8 ships the subset of Flutter's built-in
/// [BlendMode]s that photo editors commonly expose; custom modes like
/// soft light / pin light / vivid light require shader fragments and
/// land in a later phase.
///
/// Stored in the pipeline as a string (`blendMode.name`) so pipelines
/// serialize cleanly. [LayerBlendModeX.fromName] parses it back with a
/// fallback to [normal].
enum LayerBlendMode {
  normal,
  multiply,
  screen,
  overlay,
  darken,
  lighten,
  colorDodge,
  colorBurn,
  hardLight,
  softLight,
  difference,
  exclusion,
  plus,
}

extension LayerBlendModeX on LayerBlendMode {
  /// Flutter's built-in [BlendMode] that produces the same result.
  BlendMode get flutter {
    switch (this) {
      case LayerBlendMode.normal:
        return BlendMode.srcOver;
      case LayerBlendMode.multiply:
        return BlendMode.multiply;
      case LayerBlendMode.screen:
        return BlendMode.screen;
      case LayerBlendMode.overlay:
        return BlendMode.overlay;
      case LayerBlendMode.darken:
        return BlendMode.darken;
      case LayerBlendMode.lighten:
        return BlendMode.lighten;
      case LayerBlendMode.colorDodge:
        return BlendMode.colorDodge;
      case LayerBlendMode.colorBurn:
        return BlendMode.colorBurn;
      case LayerBlendMode.hardLight:
        return BlendMode.hardLight;
      case LayerBlendMode.softLight:
        return BlendMode.softLight;
      case LayerBlendMode.difference:
        return BlendMode.difference;
      case LayerBlendMode.exclusion:
        return BlendMode.exclusion;
      case LayerBlendMode.plus:
        return BlendMode.plus;
    }
  }

  /// Short user-facing label for pickers.
  String get label {
    switch (this) {
      case LayerBlendMode.normal:
        return 'Normal';
      case LayerBlendMode.multiply:
        return 'Multiply';
      case LayerBlendMode.screen:
        return 'Screen';
      case LayerBlendMode.overlay:
        return 'Overlay';
      case LayerBlendMode.darken:
        return 'Darken';
      case LayerBlendMode.lighten:
        return 'Lighten';
      case LayerBlendMode.colorDodge:
        return 'Color Dodge';
      case LayerBlendMode.colorBurn:
        return 'Color Burn';
      case LayerBlendMode.hardLight:
        return 'Hard Light';
      case LayerBlendMode.softLight:
        return 'Soft Light';
      case LayerBlendMode.difference:
        return 'Difference';
      case LayerBlendMode.exclusion:
        return 'Exclusion';
      case LayerBlendMode.plus:
        return 'Plus';
    }
  }

  /// Parse a persisted blend-mode name. Unknown names fall back to
  /// [normal] so historical pipelines keep working.
  static LayerBlendMode fromName(String? name) {
    if (name == null) return LayerBlendMode.normal;
    for (final m in LayerBlendMode.values) {
      if (m.name == name) return m;
    }
    return LayerBlendMode.normal;
  }
}
