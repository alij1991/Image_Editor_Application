import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:image_editor/engine/pipeline/edit_op_type.dart';
import 'package:image_editor/engine/pipeline/edit_operation.dart';
import 'package:image_editor/engine/pipeline/edit_pipeline.dart';
import 'package:image_editor/engine/pipeline/mask_data.dart';
import 'package:image_editor/engine/pipeline/pipeline_serializer.dart';

void main() {
  group('EditPipeline', () {
    test('append / remove / replace / reorder', () {
      final op1 = EditOperation.create(
        type: EditOpType.brightness,
        parameters: {'value': 0.1},
      );
      final op2 = EditOperation.create(
        type: EditOpType.contrast,
        parameters: {'value': 0.2},
      );
      final op3 = EditOperation.create(
        type: EditOpType.saturation,
        parameters: {'value': -0.1},
      );

      var p = EditPipeline.forOriginal('/tmp/img.jpg');
      p = p.append(op1).append(op2).append(op3);
      expect(p.operations.length, 3);
      expect(p.activeCount, 3);

      p = p.toggleEnabled(op2.id);
      expect(p.operations[1].enabled, false);
      expect(p.activeCount, 2);

      p = p.reorder(0, 2);
      expect(p.operations[0].id, op2.id);
      expect(p.operations[1].id, op3.id);
      expect(p.operations[2].id, op1.id);

      p = p.remove(op3.id);
      expect(p.operations.length, 2);
      expect(p.operations.any((o) => o.id == op3.id), false);
    });

    test('setAllEnabled', () {
      var p = EditPipeline.forOriginal('/tmp/img.jpg');
      p = p.append(EditOperation.create(
        type: EditOpType.brightness,
        parameters: {'value': 0.1},
      ));
      p = p.append(EditOperation.create(
        type: EditOpType.contrast,
        parameters: {'value': 0.1},
      ));
      expect(p.activeCount, 2);
      p = p.setAllEnabled(false);
      expect(p.activeCount, 0);
      p = p.setAllEnabled(true);
      expect(p.activeCount, 2);
    });
  });

  group('PipelineSerializer', () {
    final serializer = PipelineSerializer();

    test('roundtrip small pipeline (plain marker)', () {
      final pipeline = EditPipeline.forOriginal('/tmp/img.jpg').append(
        EditOperation.create(
          type: EditOpType.brightness,
          parameters: {'value': 0.25},
        ),
      );

      final bytes = serializer.encode(pipeline);
      expect(bytes.first, 0x00); // plain marker for small payload

      final decoded = serializer.decode(bytes);
      expect(decoded.operations.length, 1);
      expect(decoded.operations.first.type, EditOpType.brightness);
      expect(decoded.operations.first.parameters['value'], 0.25);
      expect(decoded.originalImagePath, '/tmp/img.jpg');
    });

    test('roundtrip preserves mask data', () {
      final op = EditOperation.create(
        type: EditOpType.vibrance,
        parameters: {'value': 0.5},
        mask: const MaskData(
          kind: MaskKind.radialGradient,
          feather: 0.2,
          parameters: {'cx': 0.5, 'cy': 0.5, 'radius': 0.3},
        ),
      );
      final pipeline = EditPipeline.forOriginal('/tmp/img.jpg').append(op);

      final encoded = serializer.encodeJsonString(pipeline);
      final decoded = serializer.decodeJsonString(encoded);
      final decodedOp = decoded.operations.single;
      expect(decodedOp.mask?.kind, MaskKind.radialGradient);
      expect(decodedOp.mask?.feather, closeTo(0.2, 1e-9));
      expect(decodedOp.mask?.parameters['radius'], 0.3);
    });

    test('gzip path triggers for large payloads', () {
      var pipeline = EditPipeline.forOriginal('/tmp/img.jpg');
      // Build a pipeline with enough ops to exceed the 64 KB threshold.
      for (int i = 0; i < 2000; i++) {
        pipeline = pipeline.append(EditOperation.create(
          type: EditOpType.brightness,
          parameters: {
            'value': i * 0.0001,
            'filler': List.generate(20, (j) => 'x' * 4),
          },
        ));
      }
      final bytes = serializer.encode(pipeline);
      expect(bytes.first, 0x01); // gzip marker

      final decoded = serializer.decode(bytes);
      expect(decoded.operations.length, 2000);
    });

    test('schema version is stamped on encode', () {
      final pipeline = EditPipeline.forOriginal('/tmp/img.jpg');
      final json = serializer.encodeJsonString(pipeline);
      expect(json.contains('"version":'), true);
    });
  });

  group('PipelineSerializer migration', () {
    final serializer = PipelineSerializer();

    test('pre-schema (v0) pipeline loads cleanly via the migrator', () {
      // Build a v1 pipeline, then strip the version field to simulate
      // a pre-schema document on disk. The migrator's v0 → v1 step
      // must accept it and stamp the current version.
      final pipeline = EditPipeline.forOriginal('/tmp/v0.jpg').append(
        EditOperation.create(
          type: EditOpType.brightness,
          parameters: {'value': 0.15},
        ),
      );
      final full = jsonDecode(serializer.encodeJsonString(pipeline))
          as Map<String, dynamic>;
      full.remove('version');

      // Ensure the fixture is genuinely unversioned.
      expect(full.containsKey('version'), false);

      final loaded = serializer.decodeJsonString(jsonEncode(full));
      expect(loaded.operations.length, 1);
      expect(loaded.operations.first.type, EditOpType.brightness);
      expect(loaded.operations.first.parameters['value'], 0.15);
      // After the migration the loaded pipeline runs at currentVersion.
      expect(loaded.version, PipelineSerializer.currentVersion);
    });

    test('future-version pipeline is parsed best-effort', () {
      final pipeline = EditPipeline.forOriginal('/tmp/future.jpg');
      final full = jsonDecode(serializer.encodeJsonString(pipeline))
          as Map<String, dynamic>;
      full['version'] = 999;
      // Parsing shouldn't throw; the migrator leaves the map in place
      // and `fromJson` tolerates unknown fields.
      final loaded = serializer.decodeJsonString(jsonEncode(full));
      expect(loaded.version, 999);
    });

    test('pipelines with removed op types round-trip without crashing',
        () {
      // Phase I.6 deleted `EditOpType.aiColorize` ('ai.colorize') because
      // no service was ever wired up and the manifest URL was a literal
      // example.com placeholder. Users on the previous build may still
      // have persisted pipelines containing that op string. This test
      // pins the contract that such files deserialise cleanly — the op
      // survives as an opaque EditOperation whose type no renderer
      // branch matches, so `_passesFor()` skips it.
      //
      // Build the pipeline via raw JSON because the constant is gone
      // from `EditOpType`; going through `EditOperation.create` with a
      // hand-typed string reproduces exactly what's on disk for a user
      // who saved a colorize op pre-upgrade.
      const legacyJson = '''
{
  "original_image_path": "/tmp/legacy.jpg",
  "version": 1,
  "operations": [
    {
      "id": "op-1",
      "type": "color.brightness",
      "parameters": {"value": 0.2},
      "enabled": true,
      "timestamp": "2025-01-01T00:00:00.000Z"
    },
    {
      "id": "op-2",
      "type": "ai.colorize",
      "parameters": {},
      "enabled": true,
      "timestamp": "2025-01-01T00:00:01.000Z"
    },
    {
      "id": "op-3",
      "type": "color.contrast",
      "parameters": {"value": 0.1},
      "enabled": true,
      "timestamp": "2025-01-01T00:00:02.000Z"
    }
  ],
  "metadata": {}
}
''';
      final loaded = serializer.decodeJsonString(legacyJson);
      expect(loaded.operations.length, 3,
          reason: 'every op must survive load, removed types included');
      // The legacy op string is preserved verbatim — downstream render
      // code treats it as an unknown type and renders nothing for it.
      expect(loaded.operations[1].type, 'ai.colorize');
      // The neighbouring known ops are unaffected.
      expect(loaded.operations[0].type, EditOpType.brightness);
      expect(loaded.operations[2].type, EditOpType.contrast);
    });
  });

  group('PipelineSerializer.decodeFromMap', () {
    // Added in Phase IV.2 so [ProjectStore.load] can hand its
    // already-parsed pipeline sub-map straight to the migration seam
    // without a JSON-encode-then-decode roundtrip. These tests pin
    // the contract that decodeFromMap is semantically identical to
    // decodeJsonString(jsonEncode(map)).
    final serializer = PipelineSerializer();

    test('decodeFromMap is equivalent to decodeJsonString for a v1 map',
        () {
      final pipeline = EditPipeline.forOriginal('/tmp/eq.jpg').append(
        EditOperation.create(
          type: EditOpType.saturation,
          parameters: {'value': -0.3},
        ),
      );
      final encoded = serializer.encodeJsonString(pipeline);
      final viaString = serializer.decodeJsonString(encoded);
      final viaMap = serializer
          .decodeFromMap(jsonDecode(encoded) as Map<String, dynamic>);
      expect(viaMap.originalImagePath, viaString.originalImagePath);
      expect(viaMap.version, viaString.version);
      expect(viaMap.operations.length, viaString.operations.length);
      expect(viaMap.operations.first.type, viaString.operations.first.type);
      expect(
        viaMap.operations.first.parameters['value'],
        viaString.operations.first.parameters['value'],
      );
    });

    test('decodeFromMap runs the v0 → v1 migrator like decodeJsonString',
        () {
      // Strip the version field to simulate a pre-schema pipeline map
      // — the same scenario the "v0 loads cleanly" test above covers
      // for decodeJsonString. The in-memory path must agree.
      final pipeline = EditPipeline.forOriginal('/tmp/v0map.jpg').append(
        EditOperation.create(
          type: EditOpType.brightness,
          parameters: {'value': 0.15},
        ),
      );
      final map = jsonDecode(serializer.encodeJsonString(pipeline))
          as Map<String, dynamic>;
      map.remove('version');
      final loaded = serializer.decodeFromMap(map);
      expect(loaded.operations.length, 1);
      expect(loaded.version, PipelineSerializer.currentVersion);
    });

    test('decodeFromMap preserves operation order and mask data', () {
      final op1 = EditOperation.create(
        type: EditOpType.brightness,
        parameters: {'value': 0.1},
      );
      final op2 = EditOperation.create(
        type: EditOpType.vibrance,
        parameters: {'value': 0.4},
        mask: const MaskData(
          kind: MaskKind.radialGradient,
          feather: 0.15,
          parameters: {'cx': 0.5, 'cy': 0.5, 'radius': 0.25},
        ),
      );
      final pipeline =
          EditPipeline.forOriginal('/tmp/order.jpg').append(op1).append(op2);
      final map = jsonDecode(serializer.encodeJsonString(pipeline))
          as Map<String, dynamic>;
      final loaded = serializer.decodeFromMap(map);
      expect(loaded.operations.map((o) => o.type).toList(),
          [EditOpType.brightness, EditOpType.vibrance]);
      expect(loaded.operations.last.mask?.kind, MaskKind.radialGradient);
    });
  });
}
