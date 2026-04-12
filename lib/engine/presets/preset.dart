import 'package:freezed_annotation/freezed_annotation.dart';

import '../pipeline/edit_operation.dart';

part 'preset.freezed.dart';
part 'preset.g.dart';

/// A saved recipe of edit operations. Applying a preset stamps each op
/// in [operations] into the active pipeline (replacing matching-type
/// ops so presets behave like a one-shot "apply these adjustments").
///
/// Presets come from two sources:
///   - Built-in: declared in `built_in_presets.dart`.
///   - Custom: saved by the user to sqflite.
@freezed
class Preset with _$Preset {
  @JsonSerializable(explicitToJson: true)
  const factory Preset({
    required String id,
    required String name,
    required List<EditOperation> operations,
    String? thumbnailAssetPath,
    @Default(false) bool builtIn,
    String? category,
  }) = _Preset;

  factory Preset.fromJson(Map<String, dynamic> json) => _$PresetFromJson(json);
}
