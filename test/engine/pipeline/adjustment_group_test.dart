import 'package:flutter_test/flutter_test.dart';

import 'package:image_editor/engine/layers/layer_blend_mode.dart';
import 'package:image_editor/engine/pipeline/adjustment_group.dart';
import 'package:image_editor/engine/pipeline/edit_operation.dart';
import 'package:image_editor/engine/pipeline/edit_pipeline.dart';
import 'package:image_editor/engine/pipeline/mask_data.dart';

/// Phase XVI.60 — adjustment-layer Z-order rendering, data model.
///
/// These tests pin the persistence + operations layer that the
/// future renderer integration will sit on top of. Coverage:
///
///   1. AdjustmentGroup factory + JSON round-trip + isUnmasked.
///   2. EditPipeline group operations: add, remove, update,
///      reorder.
///   3. Op membership operations: addOpToGroup, removeOpFromGroup,
///      removeGroup-clears-layerIds.
///   4. Queries: opsForGroup, unscopedOps, opGroupMap,
///      findGroupForOp, findGroupById.
///   5. Group-scoped enabled toggle.
///   6. Full pipeline JSON round-trip including groups.
void main() {
  EditOperation makeOp(String id, {String? layerId}) => EditOperation(
        id: id,
        type: 'color.brightness',
        parameters: const {'value': 0.1},
        timestamp: DateTime(2026, 4, 28),
        layerId: layerId,
      );

  group('AdjustmentGroup factory + invariants', () {
    test('AdjustmentGroup.create fills sensible defaults', () {
      final g = AdjustmentGroup.create(name: 'Adj 1');
      expect(g.id, isNotEmpty);
      expect(g.name, 'Adj 1');
      expect(g.opacity, 1.0);
      expect(g.blendMode, LayerBlendMode.normal);
      expect(g.mask, isNull);
      expect(g.enabled, isTrue);
      expect(g.isUnmasked, isTrue);
    });

    test('isUnmasked is true for null mask AND fullImage mask', () {
      final unmasked = AdjustmentGroup.create(name: 'a');
      expect(unmasked.isUnmasked, isTrue);

      final fullImage = unmasked.copyWith(
        mask: const MaskData(kind: MaskKind.fullImage),
      );
      expect(fullImage.isUnmasked, isTrue);

      final brushed = unmasked.copyWith(
        mask: const MaskData(kind: MaskKind.brush, maskAssetId: 'a'),
      );
      expect(brushed.isUnmasked, isFalse);
    });

    test('JSON round-trip preserves every field', () {
      const original = AdjustmentGroup(
        id: 'fixed-id-42',
        name: 'Sky boost',
        opacity: 0.75,
        blendMode: LayerBlendMode.screen,
        mask: MaskData(
          kind: MaskKind.brush,
          maskAssetId: 'mask-7',
          feather: 4.0,
          inverted: true,
        ),
        enabled: false,
      );
      final restored = AdjustmentGroup.fromJson(original.toJson());
      expect(restored, original);
      // Spot-check the blend mode survived the converter.
      expect(restored.blendMode, LayerBlendMode.screen);
    });

    test('JSON tolerates unknown blend mode (falls back to normal)', () {
      // Hand-construct payload with a bogus blend name — the
      // converter should clamp to LayerBlendMode.normal so old
      // pipelines from a future schema don't break the user.
      final json = <String, dynamic>{
        'id': 'g',
        'name': 'g',
        'opacity': 1.0,
        'blendMode': 'extraTerrestrialLight',
        'mask': null,
        'enabled': true,
      };
      final restored = AdjustmentGroup.fromJson(json);
      expect(restored.blendMode, LayerBlendMode.normal);
    });
  });

  group('EditPipeline group operations', () {
    test('addGroup appends; addOpToGroup tags the op via layerId', () {
      final pipeline = EditPipeline.forOriginal('/img.jpg').append(makeOp('o1'));
      final group = AdjustmentGroup.create(name: 'g1');
      final p = pipeline.addGroup(group).addOpToGroup(
            opId: 'o1',
            groupId: group.id,
          );
      expect(p.adjustmentGroups, hasLength(1));
      expect(p.adjustmentGroups.first.id, group.id);
      // Op's layerId now points at the group.
      expect(p.findById('o1')!.layerId, group.id);
    });

    test('addOpToGroup is a no-op when either id is unknown', () {
      final pipeline = EditPipeline.forOriginal('/img.jpg').append(makeOp('o1'));
      // Group does not exist yet.
      final p1 = pipeline.addOpToGroup(opId: 'o1', groupId: 'ghost');
      expect(p1, pipeline);
      // Group exists but op does not.
      final group = AdjustmentGroup.create(name: 'g');
      final p2 = pipeline.addGroup(group).addOpToGroup(
            opId: 'phantom',
            groupId: group.id,
          );
      expect(p2.findById('o1')!.layerId, isNull);
    });

    test('removeOpFromGroup clears layerId only', () {
      final group = AdjustmentGroup.create(name: 'g');
      final pipeline = EditPipeline.forOriginal('/img.jpg')
          .append(makeOp('o1'))
          .addGroup(group)
          .addOpToGroup(opId: 'o1', groupId: group.id);
      expect(pipeline.findById('o1')!.layerId, group.id);
      final cleared = pipeline.removeOpFromGroup('o1');
      expect(cleared.findById('o1')!.layerId, isNull);
      // Group still in the list — only the membership cleared.
      expect(cleared.adjustmentGroups, hasLength(1));
    });

    test('removeGroup clears layerId on every member op', () {
      final g1 = AdjustmentGroup.create(name: 'g1');
      final g2 = AdjustmentGroup.create(name: 'g2');
      final pipeline = EditPipeline.forOriginal('/img.jpg')
          .append(makeOp('o1'))
          .append(makeOp('o2'))
          .append(makeOp('o3'))
          .addGroup(g1)
          .addGroup(g2)
          .addOpToGroup(opId: 'o1', groupId: g1.id)
          .addOpToGroup(opId: 'o2', groupId: g1.id)
          .addOpToGroup(opId: 'o3', groupId: g2.id);
      // Drop g1 — o1 and o2 lose their layerId; o3 keeps g2.
      final p = pipeline.removeGroup(g1.id);
      expect(p.adjustmentGroups, hasLength(1));
      expect(p.adjustmentGroups.first.id, g2.id);
      expect(p.findById('o1')!.layerId, isNull);
      expect(p.findById('o2')!.layerId, isNull);
      expect(p.findById('o3')!.layerId, g2.id);
    });

    test('removeGroup is a no-op when id missing', () {
      final pipeline = EditPipeline.forOriginal('/img.jpg').append(makeOp('o1'));
      final out = pipeline.removeGroup('ghost');
      expect(out, pipeline);
    });

    test('updateGroup replaces by id', () {
      final original = AdjustmentGroup.create(name: 'orig');
      final pipeline =
          EditPipeline.forOriginal('/img.jpg').addGroup(original);
      final renamed = original.copyWith(name: 'Renamed');
      final p = pipeline.updateGroup(renamed);
      expect(p.adjustmentGroups.first.name, 'Renamed');
    });

    test('updateGroup with unknown id is a no-op', () {
      final pipeline = EditPipeline.forOriginal('/img.jpg');
      final phantom = AdjustmentGroup.create(name: 'phantom');
      expect(pipeline.updateGroup(phantom), pipeline);
    });

    test('reorderGroups moves a group within the list', () {
      final g1 = AdjustmentGroup.create(name: 'g1');
      final g2 = AdjustmentGroup.create(name: 'g2');
      final g3 = AdjustmentGroup.create(name: 'g3');
      final pipeline = EditPipeline.forOriginal('/img.jpg')
          .addGroup(g1)
          .addGroup(g2)
          .addGroup(g3);
      // [g1, g2, g3] → move 0 to 2 → [g2, g3, g1].
      final p = pipeline.reorderGroups(0, 2);
      expect(p.adjustmentGroups.map((g) => g.name).toList(),
          ['g2', 'g3', 'g1']);
    });

    test('reorderGroups bounds-checks gracefully', () {
      final pipeline = EditPipeline.forOriginal('/img.jpg')
          .addGroup(AdjustmentGroup.create(name: 'g1'));
      expect(pipeline.reorderGroups(0, 0), pipeline);
      expect(pipeline.reorderGroups(-1, 0), pipeline);
      expect(pipeline.reorderGroups(99, 0), pipeline);
    });
  });

  group('EditPipeline group queries', () {
    test('opsForGroup returns only the matched ops', () {
      final g = AdjustmentGroup.create(name: 'g');
      final pipeline = EditPipeline.forOriginal('/img.jpg')
          .append(makeOp('o1'))
          .append(makeOp('o2'))
          .append(makeOp('o3'))
          .addGroup(g)
          .addOpToGroup(opId: 'o1', groupId: g.id)
          .addOpToGroup(opId: 'o3', groupId: g.id);
      final scoped = pipeline.opsForGroup(g.id).toList();
      expect(scoped.map((o) => o.id).toList(), ['o1', 'o3']);
    });

    test('opsForGroup is empty for unknown group id', () {
      final pipeline = EditPipeline.forOriginal('/img.jpg').append(makeOp('o1'));
      expect(pipeline.opsForGroup('ghost'), isEmpty);
    });

    test('unscopedOps excludes group members', () {
      final g = AdjustmentGroup.create(name: 'g');
      final pipeline = EditPipeline.forOriginal('/img.jpg')
          .append(makeOp('o1'))
          .append(makeOp('o2'))
          .addGroup(g)
          .addOpToGroup(opId: 'o2', groupId: g.id);
      final unscoped = pipeline.unscopedOps.toList();
      expect(unscoped.map((o) => o.id).toList(), ['o1']);
    });

    test('opGroupMap returns all op→group bindings', () {
      final g = AdjustmentGroup.create(name: 'g');
      final pipeline = EditPipeline.forOriginal('/img.jpg')
          .append(makeOp('o1'))
          .append(makeOp('o2'))
          .addGroup(g)
          .addOpToGroup(opId: 'o2', groupId: g.id);
      expect(pipeline.opGroupMap, {'o2': g.id});
    });

    test('findGroupForOp resolves the owning group', () {
      final g = AdjustmentGroup.create(name: 'g');
      final pipeline = EditPipeline.forOriginal('/img.jpg')
          .append(makeOp('o1'))
          .addGroup(g)
          .addOpToGroup(opId: 'o1', groupId: g.id);
      expect(pipeline.findGroupForOp('o1')?.id, g.id);
      expect(pipeline.findGroupForOp('phantom'), isNull);
    });

    test('findGroupById returns null for unknown ids', () {
      final pipeline = EditPipeline.forOriginal('/img.jpg');
      expect(pipeline.findGroupById('ghost'), isNull);
    });
  });

  group('EditPipeline.setGroupEnabled', () {
    test('flips every member op enabled flag', () {
      final g = AdjustmentGroup.create(name: 'g');
      final pipeline = EditPipeline.forOriginal('/img.jpg')
          .append(makeOp('o1'))
          .append(makeOp('o2'))
          .append(makeOp('o3'))
          .addGroup(g)
          .addOpToGroup(opId: 'o1', groupId: g.id)
          .addOpToGroup(opId: 'o3', groupId: g.id);
      // Disable group ops only — o2 stays enabled.
      final disabled = pipeline.setGroupEnabled(
        groupId: g.id,
        enabled: false,
      );
      expect(disabled.findById('o1')!.enabled, isFalse);
      expect(disabled.findById('o2')!.enabled, isTrue);
      expect(disabled.findById('o3')!.enabled, isFalse);
      // Re-enable.
      final reEnabled = disabled.setGroupEnabled(
        groupId: g.id,
        enabled: true,
      );
      expect(reEnabled.findById('o1')!.enabled, isTrue);
      expect(reEnabled.findById('o3')!.enabled, isTrue);
    });
  });

  group('EditPipeline JSON round-trip with groups', () {
    test('groups + member ops survive fromJson/toJson', () {
      const g = AdjustmentGroup(
        id: 'g-1',
        name: 'Sky',
        opacity: 0.5,
        blendMode: LayerBlendMode.multiply,
        mask: MaskData(kind: MaskKind.brush, maskAssetId: 'm-1'),
        enabled: true,
      );
      final pipeline = EditPipeline.forOriginal('/img.jpg')
          .append(makeOp('o1'))
          .addGroup(g)
          .addOpToGroup(opId: 'o1', groupId: g.id);
      final json = pipeline.toJson();
      final restored = EditPipeline.fromJson(json);
      expect(restored.adjustmentGroups, hasLength(1));
      expect(restored.adjustmentGroups.first.id, 'g-1');
      expect(restored.adjustmentGroups.first.blendMode,
          LayerBlendMode.multiply);
      expect(restored.findById('o1')!.layerId, 'g-1');
    });

    test('legacy pipeline JSON without adjustment_groups round-trips', () {
      // Simulate a saved pipeline from before XVI.60 — no groups
      // field at all. Should default to empty list. Note the
      // snake_case keys: json_serializable applies `field_rename:
      // snake` so the persisted form is `original_image_path` etc.
      final json = <String, dynamic>{
        'original_image_path': '/img.jpg',
        'operations': <Map<String, dynamic>>[],
        'metadata': <String, dynamic>{},
        'version': 1,
      };
      final restored = EditPipeline.fromJson(json);
      expect(restored.originalImagePath, '/img.jpg');
      expect(restored.adjustmentGroups, isEmpty);
    });
  });
}
