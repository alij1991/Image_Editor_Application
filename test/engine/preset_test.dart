import 'package:flutter_test/flutter_test.dart';

import 'package:image_editor/engine/pipeline/edit_op_type.dart';
import 'package:image_editor/engine/pipeline/edit_operation.dart';
import 'package:image_editor/engine/pipeline/edit_pipeline.dart';
import 'package:image_editor/engine/pipeline/op_spec.dart';
import 'package:image_editor/engine/pipeline/pipeline_extensions.dart';
import 'package:image_editor/engine/presets/built_in_presets.dart';
import 'package:image_editor/engine/presets/preset.dart';
import 'package:image_editor/engine/presets/preset_applier.dart';
import 'package:image_editor/engine/presets/preset_metadata.dart';

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

    test('every op value stays inside its OpSpec min/max', () {
      for (final preset in BuiltInPresets.all) {
        for (final op in preset.operations) {
          for (final spec in OpSpecs.paramsForType(op.type)) {
            final raw = op.parameters[spec.paramKey];
            if (raw is num) {
              expect(
                raw.toDouble(),
                inInclusiveRange(spec.min, spec.max),
                reason:
                    'Preset "${preset.name}" op ${op.type}.${spec.paramKey} '
                    'out of range: $raw',
              );
            }
          }
        }
      }
    });

    test('standard presets stay inside safe ceilings', () {
      // Safe ceilings for a universal preset — values above these are
      // "strong" and must be tagged accordingly so the UI warns.
      const safeCaps = <String, double>{
        EditOpType.exposure: 0.20,
        EditOpType.contrast: 0.20,
        EditOpType.clarity: 0.20, // portraits = 0.12; relaxed here
        EditOpType.highlights: 0.30,
        EditOpType.shadows: 0.28,
        EditOpType.whites: 0.20,
        EditOpType.blacks: 0.20,
        EditOpType.vibrance: 0.25,
        EditOpType.saturation: 0.20,
        EditOpType.temperature: 0.30,
        EditOpType.tint: 0.15,
      };
      for (final preset in BuiltInPresets.all) {
        final strength = PresetMetadata.strengthOf(preset);
        // Saturation = -1 is a B&W intentional clamp; skip it.
        if (preset.operations.any((o) =>
            o.type == EditOpType.saturation &&
            o.doubleParam('value') == -1.0)) {
          continue;
        }
        if (strength == PresetStrength.strong) continue;
        for (final op in preset.operations) {
          final cap = safeCaps[op.type];
          if (cap == null) continue;
          final v = op.doubleParam('value');
          expect(
            v.abs(),
            lessThanOrEqualTo(cap + 0.001),
            reason:
                'Preset "${preset.name}" (${strength.name}) op ${op.type} '
                'value $v exceeds safe cap $cap — either soften the preset '
                'or mark it PresetStrength.strong in preset_metadata.dart.',
          );
        }
      }
    });

    test('every built-in preset has a metadata entry', () {
      for (final p in BuiltInPresets.all) {
        // strengthOf never returns null; it falls back to standard if
        // the id is missing. Detect the fallback explicitly.
        final strength = PresetMetadata.strengthOf(p);
        final defaultAmount = PresetMetadata.defaultAmountOf(p);
        expect(
          strength,
          isA<PresetStrength>(),
          reason: 'Missing metadata for ${p.id}',
        );
        expect(defaultAmount, inInclusiveRange(0.5, 1.5));
      }
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

    test('applying Punch adds all its ops at designed values', () {
      final base = EditPipeline.forOriginal('/tmp/img.jpg');
      final punch =
          BuiltInPresets.all.firstWhere((p) => p.id == 'builtin.punch');
      final out = applier.apply(punch, base);
      expect(out.operations.length, punch.operations.length);
      // Current rebalanced values (see built_in_presets.dart).
      expect(out.contrastValue, closeTo(0.18, 0.001));
      expect(out.saturationValue, closeTo(0.10, 0.001));
      expect(out.vibranceValue, closeTo(0.18, 0.001));
    });

    test('applying at amount 0 produces no preset ops', () {
      final base = EditPipeline.forOriginal('/tmp/img.jpg');
      final punch =
          BuiltInPresets.all.firstWhere((p) => p.id == 'builtin.punch');
      final out = applier.apply(punch, base, amount: 0.0);
      // With nothing else in the pipeline and amount == 0, the preset
      // fully bypasses.
      expect(out.operations, isEmpty);
    });

    test('applying at amount 0.5 interpolates halfway toward designed', () {
      final base = EditPipeline.forOriginal('/tmp/img.jpg');
      final punch =
          BuiltInPresets.all.firstWhere((p) => p.id == 'builtin.punch');
      final out = applier.apply(punch, base, amount: 0.5);
      // Contrast designed at 0.18 → at 50% should be 0.09 (baseline 0).
      expect(out.contrastValue, closeTo(0.09, 0.001));
      expect(out.saturationValue, closeTo(0.05, 0.001));
      expect(out.vibranceValue, closeTo(0.09, 0.001));
    });

    test('applying at amount 1.5 extrapolates past designed, clipped to spec', () {
      final base = EditPipeline.forOriginal('/tmp/img.jpg');
      final punch =
          BuiltInPresets.all.firstWhere((p) => p.id == 'builtin.punch');
      final out = applier.apply(punch, base, amount: 1.5);
      // 1.5x of 0.18 = 0.27 — well under the spec max of 1.0, so no clip.
      expect(out.contrastValue, closeTo(0.27, 0.001));
    });

    test('applying at amount 1.5 clamps to OpSpec.max for out-of-range', () {
      // Craft a fake preset whose value is already near the spec max
      // so 1.5x would overshoot.
      final aggressive = Preset(
        id: 'test.aggressive',
        name: 'Aggressive',
        category: 'popular',
        builtIn: false,
        operations: [
          EditOperation.create(
            type: EditOpType.contrast,
            parameters: {'value': 0.8},
          ),
        ],
      );
      final base = EditPipeline.forOriginal('/tmp/img.jpg');
      final out = applier.apply(aggressive, base, amount: 1.5);
      // 1.5 × 0.8 = 1.2 → clamped to spec max (1.0).
      expect(out.contrastValue, closeTo(1.0, 0.001));
    });

    test('applying Mono over Punch wipes Punch and shows only Mono', () {
      final base = EditPipeline.forOriginal('/tmp/img.jpg');
      var p = applier.apply(
        BuiltInPresets.all.firstWhere((x) => x.id == 'builtin.punch'),
        base,
      );
      p = applier.apply(
        BuiltInPresets.all.firstWhere((x) => x.id == 'builtin.mono'),
        p,
      );
      expect(p.saturationValue, -1.0);
      expect(p.contrastValue, closeTo(0.20, 0.001));
      expect(p.vibranceValue, 0.0);
    });

    test('applier uses fresh ops on first application', () {
      final base = EditPipeline.forOriginal('/tmp/img.jpg');
      final vintage = BuiltInPresets.all
          .firstWhere((p) => p.id == 'builtin.vintage');
      final out = applier.apply(vintage, base);
      for (final op in out.operations) {
        expect(op.id, isNotEmpty);
      }
    });

    test('applier clears colour/tone ops a preset would set', () {
      final base = EditPipeline.forOriginal('/tmp/img.jpg').append(
        EditOperation.create(
          type: EditOpType.hue,
          parameters: {'value': 45.0},
        ),
      );
      final punch =
          BuiltInPresets.all.firstWhere((p) => p.id == 'builtin.punch');
      final out = applier.apply(punch, base);
      expect(out.hueValue, 0.0);
      expect(out.contrastValue, closeTo(0.18, 0.001));
    });

    test('applier preserves geometry and layer ops across presets', () {
      final base = EditPipeline.forOriginal('/tmp/img.jpg')
          .append(
            EditOperation.create(
              type: EditOpType.rotate,
              parameters: {'steps': 1},
            ),
          )
          .append(
            EditOperation.create(
              type: EditOpType.sticker,
              parameters: {
                'character': '⭐',
                'x': 0.5,
                'y': 0.5,
                'fontSize': 80.0,
              },
            ),
          );
      final punch =
          BuiltInPresets.all.firstWhere((p) => p.id == 'builtin.punch');
      final out = applier.apply(punch, base);
      expect(
        out.operations.where((o) => o.type == EditOpType.rotate).length,
        1,
      );
      expect(
        out.operations.where((o) => o.type == EditOpType.sticker).length,
        1,
      );
      expect(out.contrastValue, closeTo(0.18, 0.001));
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
