import 'package:flutter_test/flutter_test.dart';

import 'package:image_editor/ai/inference/sky_palette.dart';
import 'package:image_editor/ai/services/sky_replace/sky_preset.dart';
import 'package:image_editor/engine/layers/content_layer.dart';
import 'package:image_editor/engine/pipeline/edit_op_type.dart';
import 'package:image_editor/engine/pipeline/edit_operation.dart';

/// Extended audit for Phase 9g completion: stops consistency,
/// constructor guards, and session log invariants.
///
/// This test file verifies the cross-cutting invariants that
/// tie together the sky palette, picker sheet, and session
/// logging patterns established in the Phase 9 audit.
void main() {
  group('SkyPalette.stopsByPreset consistency', () {
    test('every SkyPreset enum value has a stops entry', () {
      for (final preset in SkyPreset.values) {
        expect(
          SkyPalette.stopsByPreset.containsKey(preset),
          true,
          reason: 'no stops entry for ${preset.name}',
        );
      }
    });

    test('no orphaned stops entries beyond enum values', () {
      final stopKeys = SkyPalette.stopsByPreset.keys.toList();
      const enumValues = SkyPreset.values;
      expect(stopKeys.length, enumValues.length,
          reason: 'extra or missing stops entries');
    });

    test('every stops entry has valid color stops', () {
      for (final entry in SkyPalette.stopsByPreset.entries) {
        final preset = entry.key;
        final stops = entry.value;
        expect(stops.top, isNotNull, reason: '${preset.name} missing top');
        expect(stops.bottom, isNotNull,
            reason: '${preset.name} missing bottom');
        // Validate RGB ranges
        expect(stops.top.r >= 0 && stops.top.r <= 255, true);
        expect(stops.top.g >= 0 && stops.top.g <= 255, true);
        expect(stops.top.b >= 0 && stops.top.b <= 255, true);
        expect(stops.bottom.r >= 0 && stops.bottom.r <= 255, true);
        expect(stops.bottom.g >= 0 && stops.bottom.g <= 255, true);
        expect(stops.bottom.b >= 0 && stops.bottom.b <= 255, true);
      }
    });

    test('three-stop gradients only for sunset preset', () {
      for (final entry in SkyPalette.stopsByPreset.entries) {
        final preset = entry.key;
        final stops = entry.value;
        if (preset == SkyPreset.sunset) {
          expect(stops.middle, isNotNull,
              reason: 'sunset should have middle stop');
          expect(stops.hasMiddle, true);
        } else {
          expect(stops.middle, isNull,
              reason: '${preset.name} should not have middle stop');
          expect(stops.hasMiddle, false);
        }
      }
    });

    test('sunset midPosition is within valid range', () {
      final sunset = SkyPalette.stopsByPreset[SkyPreset.sunset]!;
      expect(sunset.midPosition >= 0.0 && sunset.midPosition <= 1.0, true,
          reason: 'sunset midPosition out of bounds');
    });
  });

  group('SkyPreset enum round-tripping', () {
    test('every preset name matches persistKey', () {
      for (final preset in SkyPreset.values) {
        expect(preset.persistKey, preset.name,
            reason: 'persistKey should equal enum name');
      }
    });

    test('SkyPresetX.fromName recovers every preset from persistKey', () {
      for (final preset in SkyPreset.values) {
        final recovered = SkyPresetX.fromName(preset.persistKey);
        expect(recovered, preset,
            reason: 'fromName failed for ${preset.name}');
      }
    });

    test('fromName returns clearBlue for null', () {
      final result = SkyPresetX.fromName(null);
      expect(result, SkyPreset.clearBlue);
    });

    test('fromName returns clearBlue for unknown key', () {
      final result = SkyPresetX.fromName('unknownSkyPreset');
      expect(result, SkyPreset.clearBlue);
    });

    test('every preset has non-empty label and description', () {
      for (final preset in SkyPreset.values) {
        expect(preset.label.isNotEmpty, true,
            reason: '${preset.name} has empty label');
        expect(preset.description.isNotEmpty, true,
            reason: '${preset.name} has empty description');
      }
    });
  });

  group('AdjustmentLayer with skyReplace kind', () {
    test('skyReplace kind round-trips with skyPresetName', () {
      const source = AdjustmentLayer(
        id: 'sky-1',
        adjustmentKind: AdjustmentKind.skyReplace,
        skyPresetName: 'sunset',
      );
      final params = source.toParams();
      expect(params['adjustmentKind'], 'skyReplace');
      expect(params['skyPresetName'], 'sunset');

      final parsed = AdjustmentLayer.fromOp(
        EditOperation.create(
          type: EditOpType.adjustmentLayer,
          parameters: params,
        ).copyWith(id: 'sky-1'),
      );
      expect(parsed.adjustmentKind, AdjustmentKind.skyReplace);
      expect(parsed.skyPresetName, 'sunset');
    });

    test('skyPresetName null omitted from params', () {
      const source = AdjustmentLayer(
        id: 'sky-2',
        adjustmentKind: AdjustmentKind.skyReplace,
      );
      final params = source.toParams();
      expect(params.containsKey('skyPresetName'), false);
    });

    test('copyWith skyPresetName null clears the field', () {
      const layer = AdjustmentLayer(
        id: 'sky-3',
        adjustmentKind: AdjustmentKind.skyReplace,
        skyPresetName: 'night',
      );
      final cleared = layer.copyWith(skyPresetName: null);
      expect(cleared.skyPresetName, isNull);
    });

    test('skyReplace displayLabel is "Sky replaced"', () {
      const layer = AdjustmentLayer(
        id: 'sky-4',
        adjustmentKind: AdjustmentKind.skyReplace,
      );
      expect(layer.displayLabel, 'Sky replaced');
    });

    test('invalid skyPresetName in JSON falls back to null', () {
      final op = EditOperation.create(
        type: EditOpType.adjustmentLayer,
        parameters: const {
          'adjustmentKind': 'skyReplace',
          'skyPresetName': 42, // wrong type
          'visible': true,
          'opacity': 1.0,
        },
      );
      final parsed = AdjustmentLayer.fromOp(op);
      expect(parsed.adjustmentKind, AdjustmentKind.skyReplace);
      expect(parsed.skyPresetName, isNull);
    });
  });

  group('faceReshape and skyReplace enum ordering', () {
    test('AdjustmentKind.faceReshape precedes skyReplace', () {
      const values = AdjustmentKind.values;
      final faceReshapeIndex = values.indexOf(AdjustmentKind.faceReshape);
      final skyReplaceIndex = values.indexOf(AdjustmentKind.skyReplace);
      expect(faceReshapeIndex < skyReplaceIndex, true,
          reason: 'enum order drift between faceReshape and skyReplace');
    });

    test('both kinds are present in expected order', () {
      // Phase XVI.50 appended `aiDenoise` to the tail.
      expect(AdjustmentKind.values, [
        AdjustmentKind.backgroundRemoval,
        AdjustmentKind.portraitSmooth,
        AdjustmentKind.eyeBrighten,
        AdjustmentKind.teethWhiten,
        AdjustmentKind.faceReshape,
        AdjustmentKind.skyReplace,
        AdjustmentKind.inpaint,
        AdjustmentKind.superResolution,
        AdjustmentKind.styleTransfer,
        AdjustmentKind.hairClothesRecolour,
        AdjustmentKind.composeOnBackground,
        AdjustmentKind.composeSubject,
        AdjustmentKind.aiDenoise,
      ]);
    });
  });

  group('AdjustmentKind label and displayLabel completeness', () {
    test('every AdjustmentKind has a label', () {
      for (final kind in AdjustmentKind.values) {
        expect(kind.label.isNotEmpty, true,
            reason: 'no label for ${kind.name}');
      }
    });

    test('every AdjustmentKind has a displayLabel', () {
      for (final kind in AdjustmentKind.values) {
        final layer = AdjustmentLayer(id: 'test', adjustmentKind: kind);
        expect(layer.displayLabel.isNotEmpty, true,
            reason: 'no displayLabel for ${kind.name}');
      }
    });

    test('faceReshape displayLabel is "Face sculpted"', () {
      const layer = AdjustmentLayer(
        id: 'x',
        adjustmentKind: AdjustmentKind.faceReshape,
      );
      expect(layer.displayLabel, 'Face sculpted');
    });

    test('skyReplace displayLabel is "Sky replaced"', () {
      const layer = AdjustmentLayer(
        id: 'y',
        adjustmentKind: AdjustmentKind.skyReplace,
      );
      expect(layer.displayLabel, 'Sky replaced');
    });
  });

  group('AdjustmentLayer reshape vs sky param handling', () {
    test('faceReshape and skyReplace never coexist in same layer', () {
      // Each layer is one or the other, not both.
      const face = AdjustmentLayer(
        id: 'f',
        adjustmentKind: AdjustmentKind.faceReshape,
        reshapeParams: {'slim': 0.5},
      );
      const sky = AdjustmentLayer(
        id: 's',
        adjustmentKind: AdjustmentKind.skyReplace,
        skyPresetName: 'sunset',
      );
      // Each kind ignores the other's params
      expect(face.skyPresetName, isNull);
      expect(sky.reshapeParams, isNull);
    });

    test('reshapeParams required only for faceReshape', () {
      const noReshape = AdjustmentLayer(
        id: '1',
        adjustmentKind: AdjustmentKind.backgroundRemoval,
      );
      expect(noReshape.toParams().containsKey('reshapeParams'), false);

      const withReshape = AdjustmentLayer(
        id: '2',
        adjustmentKind: AdjustmentKind.faceReshape,
        reshapeParams: {'slim': 0.3},
      );
      expect(withReshape.toParams().containsKey('reshapeParams'), true);
    });

    test('skyPresetName required only for skyReplace', () {
      const noSky = AdjustmentLayer(
        id: '3',
        adjustmentKind: AdjustmentKind.backgroundRemoval,
      );
      expect(noSky.toParams().containsKey('skyPresetName'), false);

      const withSky = AdjustmentLayer(
        id: '4',
        adjustmentKind: AdjustmentKind.skyReplace,
        skyPresetName: 'clear',
      );
      expect(withSky.toParams().containsKey('skyPresetName'), true);
    });
  });
}
