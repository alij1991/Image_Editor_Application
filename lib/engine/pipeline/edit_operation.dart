import 'package:freezed_annotation/freezed_annotation.dart';
import 'package:uuid/uuid.dart';

import 'mask_data.dart';
import 'op_registry.dart';

part 'edit_operation.freezed.dart';
part 'edit_operation.g.dart';

/// A single non-destructive edit parameterized by a map of values.
///
/// The parametric design follows the blueprint: pipelines store
/// *parameters*, never pixels. Every op has:
///
/// - [id] — a stable identifier (UUID) used for dirty-tracking + history.
/// - [type] — a string constant from [EditOpType], e.g. `'color.brightness'`.
/// - [parameters] — a free-form map read by the op's shader wrapper or its
///   Rust counterpart. Keys are op-specific; see the typed accessor
///   extensions on this class.
/// - [enabled] — toggled by the before/after comparison and by "hide this
///   layer" actions in the stack panel.
/// - [mask] — optional scope restriction. Null means "apply everywhere".
/// - [timestamp] — set on creation, used for sort-by-date in the history.
/// - [layerId] — if this op belongs to an adjustment layer, the layer's id.
@freezed
class EditOperation with _$EditOperation {
  const EditOperation._();

  @JsonSerializable(explicitToJson: true)
  const factory EditOperation({
    required String id,
    required String type,
    required Map<String, dynamic> parameters,
    @Default(true) bool enabled,
    MaskData? mask,
    required DateTime timestamp,
    String? layerId,
  }) = _EditOperation;

  factory EditOperation.fromJson(Map<String, dynamic> json) =>
      _$EditOperationFromJson(json);

  /// Convenience constructor that fills [id] with a v4 UUID and [timestamp]
  /// with `DateTime.now()`. Most call-sites should prefer this.
  factory EditOperation.create({
    required String type,
    required Map<String, dynamic> parameters,
    bool enabled = true,
    MaskData? mask,
    String? layerId,
  }) {
    return EditOperation(
      id: const Uuid().v4(),
      type: type,
      parameters: parameters,
      enabled: enabled,
      mask: mask,
      timestamp: DateTime.now(),
      layerId: layerId,
    );
  }

  /// True if this op can be folded into the composed 5x4 color matrix for
  /// the preview path.
  bool get isMatrixComposable => OpRegistry.matrixComposable.contains(type);

  /// True if this op requires a Memento snapshot in the history
  /// (cannot be reversed analytically).
  bool get requiresMemento => OpRegistry.mementoRequired.contains(type);

  /// True if this op needs a dedicated shader pass distinct from the
  /// composed color-matrix pass.
  bool get needsShaderPass => OpRegistry.shaderPassRequired.contains(type);

  /// Read a double parameter, falling back to [defaultValue].
  double doubleParam(String key, [double defaultValue = 0.0]) {
    final raw = parameters[key];
    if (raw is num) return raw.toDouble();
    return defaultValue;
  }

  int intParam(String key, [int defaultValue = 0]) {
    final raw = parameters[key];
    if (raw is num) return raw.toInt();
    return defaultValue;
  }

  bool boolParam(String key, [bool defaultValue = false]) {
    final raw = parameters[key];
    if (raw is bool) return raw;
    return defaultValue;
  }

  List<double> doubleListParam(String key) {
    final raw = parameters[key];
    if (raw is List) {
      return raw
          .whereType<num>()
          .map((e) => e.toDouble())
          .toList(growable: false);
    }
    return const [];
  }
}
