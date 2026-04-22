import 'op_registry.dart';

/// Metadata for a single adjustable parameter.
///
/// A Phase 4 scalar op (e.g. brightness) has exactly one [OpSpec]. A
/// multi-parameter op (e.g. vignette: amount + feather + roundness) has
/// one [OpSpec] per parameter, all sharing the same [type] but different
/// [paramKey] values. The UI groups specs that share a [group] name
/// under a section header.
///
/// [EditorSession.setScalar] uses the identity to decide whether to drop
/// the op when *all* of its parameters return to identity — keeping the
/// shader chain short.
class OpSpec {
  const OpSpec({
    required this.type,
    required this.label,
    required this.category,
    required this.min,
    required this.max,
    required this.identity,
    this.paramKey = 'value',
    this.group,
    this.description,
    this.snapBand = 0.02,
  });

  final String type;
  final String label;
  final OpCategory category;
  final double min;
  final double max;
  final double identity;
  final String paramKey;

  /// Optional display group (e.g. "Vignette"). Sibling specs with the
  /// same group + category render as a single collapsible section in
  /// the LightroomPanel.
  final String? group;

  /// Optional user-facing description shown as a tooltip when the user
  /// long-presses the slider label. Short, plain-English explanations.
  final String? description;

  /// VIII.15 — half-width of the snap-to-identity band as a fraction
  /// of (max - min). The slider pulls values within this band to the
  /// identity (e.g. exactly zero brightness) so users can land on the
  /// neutral point without painstaking precision. Default 0.02 (2%)
  /// matches the pre-VIII.15 hard-coded behaviour. Per-spec overrides:
  /// gamma uses 0.05 (the perceptual neutral point is wider in
  /// log-tone space) and hue uses 0.01 (the wheel wraps every 360°
  /// so a tighter band keeps small intentional shifts).
  final double snapBand;

  bool isIdentity(double value) => (value - identity).abs() < 1e-4;
}

// NOTE: `optics` (lens corrections) was removed in Phase II.5 because it
// had zero registered specs and no roadmap entry in Phases III–IX. When lens
// correction work is scoped, add it back here — see docs/decisions/optics-tab.md.
enum OpCategory { light, color, effects, detail, geometry }

extension OpCategoryX on OpCategory {
  String get label {
    switch (this) {
      case OpCategory.light:
        return 'Light';
      case OpCategory.color:
        return 'Color';
      case OpCategory.effects:
        return 'Effects';
      case OpCategory.detail:
        return 'Detail';
      case OpCategory.geometry:
        return 'Geometry';
    }
  }
}

/// View over every adjustable slider parameter the editor ships.
///
/// Before Phase III.1 this class held a `const List<OpSpec>` with ~40
/// entries; adding a new op required touching this list AND three
/// classifier sets on `EditOpType`. Both now live in [OpRegistry]: each
/// op declares its specs on its [OpRegistration], and this class
/// flattens them out for the call sites that read specs directly
/// (`LightroomPanel` + gesture layer) or iterate by type
/// (`EditorSession` for identity-collapse checks).
class OpSpecs {
  OpSpecs._();

  /// Every registered [OpSpec], in registry declaration order.
  /// Delegates to [OpRegistry.specs].
  static List<OpSpec> get all => OpRegistry.specs;

  /// All specs for [cat], in declaration order. The UI relies on this
  /// order — `LightroomPanel` renders specs top-to-bottom.
  static List<OpSpec> forCategory(OpCategory cat) =>
      all.where((s) => s.category == cat).toList(growable: false);

  /// Scalar spec for [type] with the default `value` param key, or
  /// null if the op has no single-scalar spec.
  static OpSpec? byType(String type) {
    for (final s in all) {
      if (s.type == type && s.paramKey == 'value') return s;
    }
    return null;
  }

  /// All specs that belong to a given op type. Used by EditorSession to
  /// decide whether ALL parameters of a multi-param op have returned to
  /// identity.
  static List<OpSpec> paramsForType(String type) =>
      all.where((s) => s.type == type).toList(growable: false);
}
