import '../pipeline/edit_op_type.dart';
import '../pipeline/edit_operation.dart';
import '../pipeline/op_spec.dart';
import 'preset.dart';

/// Blends a [Preset]'s operations against a per-op baseline at a given
/// amount, producing the actual ops that should be appended to the
/// pipeline.
///
/// This is what powers the per-preset "Amount" slider (Lightroom Mobile
/// / VSCO Strength). At `amount = 0` the output is empty (= preset
/// fully undone, baseline photo shows through). At `amount = 1.0` the
/// output matches the preset exactly. At `amount = 1.5` each
/// interpolating param is extrapolated 50% beyond the preset's
/// designed value, clipped to the `OpSpec` min/max.
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

  /// Per-op-type set of keys that should interpolate linearly with the
  /// amount. Keys not listed here either:
  ///   - use their preset-literal value whenever `amount > 0` (shape
  ///     parameters like vignette feather/roundness, grain cellSize —
  ///     varying these with amount produces visible strobing), or
  ///   - are non-numeric (like splitToning colour triples) and are
  ///     included verbatim whenever `amount > 0`.
  ///
  /// When an op has zero interpolating keys and `amount == 0`, the op
  /// is dropped entirely from the output.
  static const Map<String, Set<String>> _interpolatingKeys = {
    EditOpType.exposure: {'value'},
    EditOpType.brightness: {'value'},
    EditOpType.contrast: {'value'},
    EditOpType.saturation: {'value'},
    EditOpType.hue: {'value'},
    EditOpType.vibrance: {'value'},
    EditOpType.temperature: {'value'},
    EditOpType.tint: {'value'},
    EditOpType.highlights: {'value'},
    EditOpType.shadows: {'value'},
    EditOpType.whites: {'value'},
    EditOpType.blacks: {'value'},
    EditOpType.clarity: {'value'},
    EditOpType.dehaze: {'value'},
    EditOpType.vignette: {'amount'},
    EditOpType.grain: {'amount'},
    EditOpType.sharpen: {'amount'},
  };

  /// Returns the ops to append to the pipeline at the given [amount].
  ///
  /// [amount] is a 0.0–1.5 multiplier (0 = no effect, 1.0 = preset as
  /// designed, 1.5 = 50% beyond). Values outside this range are
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
    final clampedAmount = amount.clamp(0.0, 1.5);
    // At amount = 0 the preset is fully undone — no ops to append.
    if (clampedAmount == 0.0) return const [];

    final out = <EditOperation>[];
    for (final op in preset.operations) {
      final interpolating = _interpolatingKeys[op.type] ?? const <String>{};
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
