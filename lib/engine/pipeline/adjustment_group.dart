import 'package:freezed_annotation/freezed_annotation.dart';
import 'package:uuid/uuid.dart';

import '../layers/layer_blend_mode.dart';
import 'mask_data.dart';

part 'adjustment_group.freezed.dart';
part 'adjustment_group.g.dart';

/// JSON converter for [LayerBlendMode]. The enum imports `dart:ui`,
/// which trips json_serializable's auto-generation, so we go via
/// the enum's stable `.name` string — exactly the persistence
/// contract `LayerBlendModeX.fromName` already documents.
String _blendToJson(LayerBlendMode mode) => mode.name;
LayerBlendMode _blendFromJson(String? name) => LayerBlendModeX.fromName(name);

/// Phase XVI.60 — adjustment-layer Z-order rendering, data model.
///
/// An [AdjustmentGroup] is a NAMED, MASK-SCOPED collection of
/// [EditOperation]s. The group's id is referenced by every member
/// op via [EditOperation.layerId]; that's how the renderer knows
/// which ops to apply through the group's mask vs the global flat
/// pipeline.
///
/// Affinity Photo iPad and Photoshop Mobile both ship this concept
/// — the user paints a mask once and a stack of brightness /
/// contrast / curves / hue ops runs only inside that region. The
/// alternative (one mask per op) gets clumsy fast for any nontrivial
/// scoped edit.
///
/// ## What ships in XVI.60
///
/// This phase ships the DATA + OPERATIONS LAYER:
///
/// 1. The [AdjustmentGroup] type itself (freezed, round-trippable).
/// 2. `EditPipeline.adjustmentGroups: List<AdjustmentGroup>` — the
///    canonical list, ordered by paint Z-order (last paints last).
/// 3. Pipeline operations for adding / removing / reordering groups
///    plus moving ops into / out of groups.
/// 4. Group-aware queries: [EditPipeline.opsForGroup],
///    [EditPipeline.unscopedOps], [EditPipeline.findGroupForOp].
/// 5. Persistence — `fromJson` / `toJson` round-trip via Freezed.
/// 6. Group-scoped enable toggle —
///    [EditPipeline.setGroupEnabled] flips every op in the group at
///    once.
///
/// ## What does NOT ship in XVI.60 (deliberate)
///
/// The RENDERING integration is genuinely large: every shader pass
/// in the chain needs to learn about a per-group mask uniform, and
/// the pass builder needs to walk groups. That's a multi-day chunk
/// (every `.frag` touched, every `_passesFor` branch revisited)
/// and is tracked as XVI.60.X / XVI.62 follow-up. The data model
/// here is the foundation the renderer change will build on:
/// shipping it lets persisted pipelines round-trip groups today,
/// which means the renderer change can be merged as a
/// rendering-only diff without touching persistence.
///
/// This is the same shape XVI.50 / 51 / 53 / 54 / 55 / 56 / 57 /
/// 58 took: ship the data + service scaffold, defer the live
/// integration step that needs separate verification.
@freezed
class AdjustmentGroup with _$AdjustmentGroup {
  const AdjustmentGroup._();

  @JsonSerializable(explicitToJson: true)
  const factory AdjustmentGroup({
    /// Stable identifier — matches `EditOperation.layerId` for member
    /// ops. Generated via UUID v4 in [AdjustmentGroup.create].
    required String id,

    /// User-visible name. Defaults to "Adjustment <n>" via
    /// [AdjustmentGroup.create] but the panel can rename.
    required String name,

    /// Group opacity, `[0, 1]`. The renderer multiplies the group's
    /// final compositing alpha by this. Default 1.
    @Default(1.0) double opacity,

    /// Blend mode for compositing the group's output onto the
    /// underlying image. Reuses the same enum the layer painter
    /// already supports — Phase XVI.43 added the full list.
    @Default(LayerBlendMode.normal)
    @JsonKey(fromJson: _blendFromJson, toJson: _blendToJson)
    LayerBlendMode blendMode,

    /// Optional mask. Null means the group still scopes its ops
    /// (so the user can disable mask painting and use the group as
    /// a NAMED stack of ops without losing the grouping).
    MaskData? mask,

    /// Group-level enabled flag. Distinct from per-op enabled —
    /// a disabled group hides every member op's contribution
    /// without touching the per-op flags.
    @Default(true) bool enabled,
  }) = _AdjustmentGroup;

  factory AdjustmentGroup.fromJson(Map<String, dynamic> json) =>
      _$AdjustmentGroupFromJson(json);

  /// Convenience constructor that fills [id] with a v4 UUID.
  factory AdjustmentGroup.create({
    required String name,
    double opacity = 1.0,
    LayerBlendMode blendMode = LayerBlendMode.normal,
    MaskData? mask,
    bool enabled = true,
  }) {
    return AdjustmentGroup(
      id: const Uuid().v4(),
      name: name,
      opacity: opacity,
      blendMode: blendMode,
      mask: mask,
      enabled: enabled,
    );
  }

  /// True when this group has no mask attached. The group still
  /// SCOPES its member ops (renderer iterates groups separately
  /// from the flat pipeline) — but it scopes them globally rather
  /// than to a region.
  bool get isUnmasked => mask == null || mask!.kind == MaskKind.fullImage;
}
