import 'package:flutter_test/flutter_test.dart';

import 'package:image_editor/engine/pipeline/edit_op_type.dart';
import 'package:image_editor/engine/pipeline/edit_operation.dart';
import 'package:image_editor/engine/pipeline/edit_pipeline.dart';
import 'package:image_editor/engine/pipeline/pipeline_extensions.dart';
import 'package:image_editor/engine/presets/built_in_presets.dart';
import 'package:image_editor/engine/presets/preset.dart';
import 'package:image_editor/engine/presets/preset_applier.dart';

void main() {
  group('BuiltInPresets', () {
    test('has at least the canonical presets', () {
      final all = BuiltInPresets.all;
      final ids = all.map((p) => p.id).toSet();
      expect(ids, contains('builtin.none'));
      expect(ids, contains('builtin.punch'));
      expect(ids, contains('builtin.mono'));
      expect(ids, contains('builtin.vintage'));
      expect(ids, contains('builtin.dramatic'));
      expect(ids, contains('builtin.noir'));
    });

    test('every preset is marked builtIn', () {
      for (final p in BuiltInPresets.all) {
        expect(p.builtIn, true, reason: p.name);
      }
    });

    test('preset ids are unique', () {
      final ids = BuiltInPresets.all.map((p) => p.id).toList();
      expect(ids.length, ids.toSet().length);
    });

    test('Mono preset drops saturation to -1', () {
      final mono = BuiltInPresets.all.firstWhere((p) => p.id == 'builtin.mono');
      final satOp = mono.operations
          .firstWhere((o) => o.type == EditOpType.saturation);
      expect(satOp.parameters['value'], -1.0);
    });
  });

  group('PresetApplier', () {
    const applier = PresetApplier();

    test('applying Original preset to empty pipeline yields empty', () {
      final base = EditPipeline.forOriginal('/tmp/img.jpg');
      final original = BuiltInPresets.all.firstWhere(
        (p) => p.id == 'builtin.none',
      );
      final out = applier.apply(original, base);
      expect(out.operations, isEmpty);
    });

    test('applying Punch adds all its ops', () {
      final base = EditPipeline.forOriginal('/tmp/img.jpg');
      final punch =
          BuiltInPresets.all.firstWhere((p) => p.id == 'builtin.punch');
      final out = applier.apply(punch, base);
      expect(out.operations.length, punch.operations.length);
      expect(out.contrastValue, 0.25);
      expect(out.saturationValue, 0.35);
      expect(out.vibranceValue, 0.20);
    });

    test('applying Mono over Punch replaces saturation, not contrast', () {
      final base = EditPipeline.forOriginal('/tmp/img.jpg');
      var p = applier.apply(
        BuiltInPresets.all.firstWhere((x) => x.id == 'builtin.punch'),
        base,
      );
      p = applier.apply(
        BuiltInPresets.all.firstWhere((x) => x.id == 'builtin.mono'),
        p,
      );
      // Mono sets saturation to -1 (replaces Punch's 0.35).
      expect(p.saturationValue, -1.0);
      // Mono sets contrast to 0.2 (replaces Punch's 0.25).
      expect(p.contrastValue, 0.2);
      // Punch's vibrance was not in Mono → should still be there.
      expect(p.vibranceValue, 0.2);
    });

    test('applier uses fresh ops on first application', () {
      final base = EditPipeline.forOriginal('/tmp/img.jpg');
      final vintage = BuiltInPresets.all
          .firstWhere((p) => p.id == 'builtin.vintage');
      final out = applier.apply(vintage, base);
      // Every op should have a non-empty id (EditOperation.create assigns UUID).
      for (final op in out.operations) {
        expect(op.id, isNotEmpty);
      }
    });

    test('applier preserves user-only ops not touched by the preset', () {
      final base = EditPipeline.forOriginal('/tmp/img.jpg').append(
        EditOperation.create(
          type: EditOpType.hue,
          parameters: {'value': 45.0},
        ),
      );
      final punch =
          BuiltInPresets.all.firstWhere((p) => p.id == 'builtin.punch');
      final out = applier.apply(punch, base);
      // Hue was not in Punch, so the user's value should survive.
      expect(out.hueValue, 45.0);
      // Punch's contrast should be stamped.
      expect(out.contrastValue, 0.25);
    });
  });

  group('Preset JSON roundtrip', () {
    test('encoding and decoding preserves operations', () {
      final source = Preset(
        id: 'test.custom',
        name: 'Test Custom',
        category: 'Custom',
        builtIn: false,
        operations: [
          EditOperation.create(
            type: EditOpType.brightness,
            parameters: {'value': 0.3},
          ),
          EditOperation.create(
            type: EditOpType.vignette,
            parameters: {'amount': 0.4, 'feather': 0.5, 'roundness': 0.5},
          ),
        ],
      );
      final json = source.toJson();
      final decoded = Preset.fromJson(json);
      expect(decoded.id, source.id);
      expect(decoded.name, source.name);
      expect(decoded.operations.length, 2);
      expect(decoded.operations.first.type, EditOpType.brightness);
      expect(decoded.operations.first.parameters['value'], 0.3);
      expect(decoded.operations.last.type, EditOpType.vignette);
      expect(decoded.operations.last.parameters['feather'], 0.5);
    });
  });
}
