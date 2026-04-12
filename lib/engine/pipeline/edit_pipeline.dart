import 'package:freezed_annotation/freezed_annotation.dart';

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
}
