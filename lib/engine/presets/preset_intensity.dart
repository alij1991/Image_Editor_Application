import '../pipeline/edit_operation.dart';
import '../pipeline/op_registry.dart';
import '../pipeline/op_spec.dart';
import 'preset.dart';

/// Blends a [Preset]'s operations against a per-op baseline at a given
/// amount, producing the actual ops that should be appended to the
/// pipeline.
///
/// This is what powers the per-preset "Amount" slider (Lightroom Mobile
/// / VSCO Strength). At `amount = 0` the output is empty (= preset
/// fully undone, baseline photo shows through). At `amount = 1.0` the
/// output matches the preset exactly. At `amount = 2.0` each
/// interpolating param is extrapolated 100% beyond the preset's
/// designed value, clipped to the `OpSpec` min/max.
///
/// Phase XVI.63 widened the cap from 1.5 to 2.0 — the per-op clamp to
/// `OpSpec.min/max` already prevents extrapolation from blowing past
/// physically-sensible ranges, so the wider slider just gives users
/// more headroom on intentionally-mild presets without changing
/// behaviour for ones already at full strength.
///
/// Mathematically:
///
/// ```
/// applied = baseline + amount * (preset - baseline)
/// ```
///
/// where `baseline` is the value each op would hold in the absence of
/// the preset — almost always the op's identity (0 for most scalars,
/// since we wipe preset-owned ops before applying). Passing a custom
/// baseline lets a caller compose a preset on top of a manually-edited
/// state if we ever decide to ship that semantic.
class PresetIntensity {
  const PresetIntensity();

  // NOTE: the per-op-type interpolating-keys map moved to the central
  // `OpRegistry` in Phase III.1. Each `OpRegistration` now declares its
  // own `interpolatingKeys` — see `op_registry.dart`. Keys not declared
  // there fall through to the literal-pass-through branch below.
  //
  // Semantic preserved: keys in the interpolating set blend linearly
  // with amount; keys NOT in the set use their preset-literal value
  // whenever `amount > 0`. Non-numeric values (colour triples, int
  // sizes that would strobe on interpolation) pass through verbatim.

  /// Returns the ops to append to the pipeline at the given [amount].
  ///
  /// [amount] is a 0.0–2.0 multiplier (0 = no effect, 1.0 = preset as
  /// designed, 2.0 = 100% beyond). Values outside this range are
  /// clamped.
  ///
  /// [baseline] is an optional override for each op-type's baseline
  /// value. If null, every op starts at its `OpSpec` identity, which
  /// matches the "replace-the-look" semantic where preset-owned ops
  /// are wiped before a preset is applied.
  List<EditOperation> blend(
    Preset preset,
    double amount, {
    double Function(String type, String paramKey)? baseline,
  }) {
    final clampedAmount = amount.clamp(0.0, 2.0);
    // At amount = 0 the preset is fully undone — no ops to append.
    if (clampedAmount == 0.0) return const [];

    final out = <EditOperation>[];
    for (final op in preset.operations) {
      final interpolating = OpRegistry.interpolatingKeysFor(op.type);
      final blended = <String, dynamic>{};
      for (final entry in op.parameters.entries) {
        final key = entry.key;
        final raw = entry.value;
        if (interpolating.contains(key) && raw is num) {
          final presetValue = raw.toDouble();
          final base = baseline != null
              ? baseline(op.type, key)
              : _identityFor(op.type, key);
          final blendedValue =
              base + clampedAmount * (presetValue - base);
          blended[key] = _clampToSpec(op.type, key, blendedValue);
        } else {
          // Pass through literal (colours, shape params, ints).
          blended[key] = raw;
        }
      }
      out.add(EditOperation.create(
        type: op.type,
        parameters: blended,
      ));
    }
    return out;
  }

  /// Identity value for `(type, paramKey)`, read from the `OpSpec`
  /// registry with sensible fallbacks for params not present there
  /// (vignette `amount`, grain `amount` etc. are registered; this
  /// covers anything that's not).
  double _identityFor(String type, String paramKey) {
    for (final spec in OpSpecs.paramsForType(type)) {
      if (spec.paramKey == paramKey) return spec.identity;
    }
    return 0.0;
  }

  /// Clamp a blended value to the registered min/max for its op spec.
  /// Prevents 150% intensity from pushing `saturation` past -1 or +1
  /// (which produces inverted colours or NaN-looking results).
  double _clampToSpec(String type, String paramKey, double value) {
    for (final spec in OpSpecs.paramsForType(type)) {
      if (spec.paramKey == paramKey) {
        return value.clamp(spec.min, spec.max);
      }
    }
    return value;
  }
}
