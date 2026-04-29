import 'package:freezed_annotation/freezed_annotation.dart';

import 'adjustment_group.dart';
import 'edit_operation.dart';

part 'edit_pipeline.freezed.dart';
part 'edit_pipeline.g.dart';

/// The root parametric state for a single image editing session.
///
/// Contains the original image path (read-only; the original is never
/// mutated) and an ordered list of [EditOperation]s applied in sequence.
///
/// Layer-based adjustments are represented by ops whose [EditOperation.layerId]
/// identifies which layer they belong to. The layer stack itself is a
/// separate concept materialized in Phase 8; Phase 1 only models the flat
/// pipeline list.
///
/// [version] is the schema version; bump it whenever the JSON format changes
/// in a way that requires migration on load.
@freezed
class EditPipeline with _$EditPipeline {
  const EditPipeline._();

  @JsonSerializable(explicitToJson: true)
  const factory EditPipeline({
    required String originalImagePath,
    @Default([]) List<EditOperation> operations,
    @Default({}) Map<String, Object?> metadata,
    @Default(1) int version,

    /// Phase XVI.60 — adjustment-layer Z-order rendering, data
    /// model. The list of [AdjustmentGroup]s in paint order (last
    /// element paints last). Member ops carry `layerId == group.id`
    /// so the renderer can resolve which ops to apply through
    /// each group's mask.
    ///
    /// Defaults to an empty list — old pipelines without this
    /// field round-trip cleanly.
    @Default(<AdjustmentGroup>[]) List<AdjustmentGroup> adjustmentGroups,
  }) = _EditPipeline;

  factory EditPipeline.fromJson(Map<String, dynamic> json) =>
      _$EditPipelineFromJson(json);

  /// Create an empty pipeline anchored on [originalImagePath].
  factory EditPipeline.forOriginal(String originalImagePath) =>
      EditPipeline(originalImagePath: originalImagePath);

  /// Return a new pipeline with [op] appended at the end.
  EditPipeline append(EditOperation op) {
    return copyWith(operations: [...operations, op]);
  }

  /// Return a new pipeline with [op] inserted at [index].
  EditPipeline insertAt(int index, EditOperation op) {
    final list = [...operations]..insert(index, op);
    return copyWith(operations: list);
  }

  /// Find the first op whose id matches [opId], or null. Unlike
  /// [PipelineReaders.findOp] this returns disabled ops as well.
  EditOperation? findById(String opId) {
    for (final op in operations) {
      if (op.id == opId) return op;
    }
    return null;
  }

  /// Return a new pipeline with the layer ops rearranged so that the
  /// layer with [layerId] ends up at position [newLayerIndex] among the
  /// layer ops, counting from the BOTTOM of the stack (paint order).
  ///
  /// The positions of non-layer (color / geometry) ops in the main
  /// operations list are preserved — only the layer slots are
  /// shuffled. [isLayer] tells the function which op types count as
  /// layers so the caller owns the type taxonomy.
  EditPipeline reorderLayers({
    required String layerId,
    required int newLayerIndex,
    required bool Function(EditOperation op) isLayer,
  }) {
    // Capture the original slot indices of every layer op.
    final slotIndices = <int>[];
    final layerOps = <EditOperation>[];
    int currentLayerIdx = -1;
    for (int i = 0; i < operations.length; i++) {
      if (isLayer(operations[i])) {
        if (operations[i].id == layerId) currentLayerIdx = layerOps.length;
        slotIndices.add(i);
        layerOps.add(operations[i]);
      }
    }
    if (currentLayerIdx < 0) return this; // id not a layer in this pipeline
    final target = newLayerIndex.clamp(0, layerOps.length - 1);
    if (target == currentLayerIdx) return this;

    final moved = layerOps.removeAt(currentLayerIdx);
    layerOps.insert(target, moved);

    // Write the rearranged layer list back into the same pipeline slots.
    final next = [...operations];
    for (int k = 0; k < slotIndices.length; k++) {
      next[slotIndices[k]] = layerOps[k];
    }
    return copyWith(operations: next);
  }

  /// Return a new pipeline with the op identified by [opId] removed.
  EditPipeline remove(String opId) {
    return copyWith(
      operations: operations.where((o) => o.id != opId).toList(),
    );
  }

  /// Return a new pipeline with the op identified by [opId] replaced.
  EditPipeline replace(EditOperation replacement) {
    return copyWith(
      operations: [
        for (final o in operations)
          if (o.id == replacement.id) replacement else o,
      ],
    );
  }

  /// Return a new pipeline with the op at index [from] moved to index [to].
  EditPipeline reorder(int from, int to) {
    if (from == to) return this;
    final list = [...operations];
    final op = list.removeAt(from);
    list.insert(to.clamp(0, list.length), op);
    return copyWith(operations: list);
  }

  /// Toggle the enabled flag on the op with [opId].
  EditPipeline toggleEnabled(String opId) {
    return copyWith(
      operations: [
        for (final o in operations)
          if (o.id == opId) o.copyWith(enabled: !o.enabled) else o,
      ],
    );
  }

  /// Set every op's enabled flag to [enabled]. Used by the tap-hold
  /// before/after comparison.
  EditPipeline setAllEnabled(bool enabled) {
    return copyWith(
      operations: [
        for (final o in operations) o.copyWith(enabled: enabled),
      ],
    );
  }

  /// The subset of operations that should actually be rendered (enabled).
  Iterable<EditOperation> get activeOperations =>
      operations.where((o) => o.enabled);

  /// Number of active (enabled) operations.
  int get activeCount => activeOperations.length;

  /// True if the pipeline has no ops at all.
  bool get isEmpty => operations.isEmpty;

  // -------------------------------------------------------------------
  // Phase XVI.60 — adjustment-group operations + queries.
  // -------------------------------------------------------------------

  /// Append [group] to the adjustment group list. Member ops still
  /// have to be added via [addOpToGroup] — creating a group is
  /// purely a metadata step.
  EditPipeline addGroup(AdjustmentGroup group) {
    return copyWith(adjustmentGroups: [...adjustmentGroups, group]);
  }

  /// Remove the group with [groupId]. Every op that was scoped to
  /// the group has its `layerId` cleared — the ops survive in the
  /// flat pipeline, the user just loses the mask and grouping.
  /// (Removing the ops along with the group would make undo
  /// surprising; we mirror Photoshop's "delete group, keep
  /// contents" default.)
  EditPipeline removeGroup(String groupId) {
    final filteredGroups =
        adjustmentGroups.where((g) => g.id != groupId).toList();
    if (filteredGroups.length == adjustmentGroups.length) {
      // Group did not exist — return self unchanged so callers can
      // safely no-op.
      return this;
    }
    final newOps = <EditOperation>[];
    for (final o in operations) {
      if (o.layerId == groupId) {
        newOps.add(o.copyWith(layerId: null));
      } else {
        newOps.add(o);
      }
    }
    return copyWith(
      operations: newOps,
      adjustmentGroups: filteredGroups,
    );
  }

  /// Replace the group whose id matches [replacement.id]. No-op
  /// when the id is not in the list.
  EditPipeline updateGroup(AdjustmentGroup replacement) {
    return copyWith(
      adjustmentGroups: [
        for (final g in adjustmentGroups)
          if (g.id == replacement.id) replacement else g,
      ],
    );
  }

  /// Move the group at index [from] to index [to] in the
  /// `adjustmentGroups` list. Member ops are not reordered; the
  /// renderer uses the group order alone for paint sequence.
  EditPipeline reorderGroups(int from, int to) {
    if (from == to) return this;
    if (from < 0 || from >= adjustmentGroups.length) return this;
    final list = [...adjustmentGroups];
    final g = list.removeAt(from);
    list.insert(to.clamp(0, list.length), g);
    return copyWith(adjustmentGroups: list);
  }

  /// Move the op identified by [opId] into the group identified by
  /// [groupId]. Sets the op's `layerId` to the group id. Returns
  /// self unchanged when either id is missing — neither side wins
  /// silently, which keeps the panel honest about scoping.
  EditPipeline addOpToGroup({required String opId, required String groupId}) {
    final groupExists = adjustmentGroups.any((g) => g.id == groupId);
    if (!groupExists) return this;
    final hasOp = operations.any((o) => o.id == opId);
    if (!hasOp) return this;
    return copyWith(
      operations: [
        for (final o in operations)
          if (o.id == opId) o.copyWith(layerId: groupId) else o,
      ],
    );
  }

  /// Clear the op's group membership — flips `layerId` to null.
  /// Returns self unchanged when the op id is unknown.
  EditPipeline removeOpFromGroup(String opId) {
    final hasOp = operations.any((o) => o.id == opId);
    if (!hasOp) return this;
    return copyWith(
      operations: [
        for (final o in operations)
          if (o.id == opId) o.copyWith(layerId: null) else o,
      ],
    );
  }

  /// All member ops of [groupId] in pipeline order. Returns an
  /// empty iterable when the group is unknown.
  Iterable<EditOperation> opsForGroup(String groupId) {
    return operations.where((o) => o.layerId == groupId);
  }

  /// All ops with no `layerId` — the flat pipeline that the
  /// existing renderer walks today. Z-order rendering layers the
  /// groups atop these.
  Iterable<EditOperation> get unscopedOps =>
      operations.where((o) => o.layerId == null);

  /// Lookup table of `op id → group id` for every op that's a
  /// group member. Useful for the panel + diagnostics; the renderer
  /// itself iterates [adjustmentGroups] directly.
  Map<String, String> get opGroupMap {
    final map = <String, String>{};
    for (final o in operations) {
      final gid = o.layerId;
      if (gid != null) map[o.id] = gid;
    }
    return map;
  }

  /// Find the [AdjustmentGroup] that contains the op with [opId],
  /// or null when the op is unscoped or unknown.
  AdjustmentGroup? findGroupForOp(String opId) {
    final op = findById(opId);
    if (op == null || op.layerId == null) return null;
    for (final g in adjustmentGroups) {
      if (g.id == op.layerId) return g;
    }
    return null;
  }

  /// Lookup a group by id, or null.
  AdjustmentGroup? findGroupById(String groupId) {
    for (final g in adjustmentGroups) {
      if (g.id == groupId) return g;
    }
    return null;
  }

  /// Set every member op's enabled flag to [enabled]. Pairs with
  /// the group-level enabled flag stored on [AdjustmentGroup]
  /// itself — call sites pick which axis to flip based on whether
  /// they want the change persisted as a group toggle (use
  /// [updateGroup]) or as per-op state.
  EditPipeline setGroupEnabled({
    required String groupId,
    required bool enabled,
  }) {
    return copyWith(
      operations: [
        for (final o in operations)
          if (o.layerId == groupId) o.copyWith(enabled: enabled) else o,
      ],
    );
  }
}
