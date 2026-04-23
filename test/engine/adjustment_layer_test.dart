import 'package:flutter_test/flutter_test.dart';

import 'package:image_editor/engine/layers/content_layer.dart';
import 'package:image_editor/engine/layers/layer_blend_mode.dart';
import 'package:image_editor/engine/layers/layer_mask.dart';
import 'package:image_editor/engine/pipeline/edit_op_type.dart';
import 'package:image_editor/engine/pipeline/edit_operation.dart';
import 'package:image_editor/engine/pipeline/edit_pipeline.dart';
import 'package:image_editor/engine/pipeline/pipeline_extensions.dart';

void main() {
  group('AdjustmentLayer', () {
    test('has identity transform (position 0.5/0.5, no scale/rotation)', () {
      const layer = AdjustmentLayer(
        id: 'id',
        adjustmentKind: AdjustmentKind.backgroundRemoval,
      );
      expect(layer.x, 0.5);
      expect(layer.y, 0.5);
      expect(layer.rotation, 0);
      expect(layer.scale, 1);
    });

    test('displayLabel matches AdjustmentKind', () {
      const layer = AdjustmentLayer(
        id: 'id',
        adjustmentKind: AdjustmentKind.backgroundRemoval,
      );
      expect(layer.displayLabel, 'Background removed');
    });

    test('kind is LayerKind.adjustment', () {
      const layer = AdjustmentLayer(
        id: 'id',
        adjustmentKind: AdjustmentKind.backgroundRemoval,
      );
      expect(layer.kind, LayerKind.adjustment);
    });

    test('copyWith preserves sibling fields', () {
      const layer = AdjustmentLayer(
        id: 'id',
        adjustmentKind: AdjustmentKind.backgroundRemoval,
        opacity: 0.75,
        blendMode: LayerBlendMode.multiply,
        mask: LayerMask(shape: MaskShape.linear),
      );
      final next = layer.copyWith(opacity: 0.5);
      expect(next.opacity, 0.5);
      expect(next.blendMode, LayerBlendMode.multiply);
      expect(next.mask.shape, MaskShape.linear);
      expect(next.adjustmentKind, AdjustmentKind.backgroundRemoval);
    });

    test('copyWith can clear cutoutImage via sentinel', () {
      const layer = AdjustmentLayer(
        id: 'id',
        adjustmentKind: AdjustmentKind.backgroundRemoval,
      );
      final next = layer.copyWith(cutoutImage: null);
      expect(next.cutoutImage, isNull);
    });

    test('round-trip through EditOperation omits volatile cutoutImage',
        () {
      const source = AdjustmentLayer(
        id: 'adj-1',
        adjustmentKind: AdjustmentKind.backgroundRemoval,
        blendMode: LayerBlendMode.screen,
      );
      final op = EditOperation.create(
        type: EditOpType.adjustmentLayer,
        parameters: source.toParams(),
      ).copyWith(id: 'adj-1');
      final parsed = AdjustmentLayer.fromOp(op);
      expect(parsed.id, 'adj-1');
      expect(parsed.adjustmentKind, AdjustmentKind.backgroundRemoval);
      expect(parsed.blendMode, LayerBlendMode.screen);
      // cutoutImage is volatile — fromOp can never reconstruct it.
      expect(parsed.cutoutImage, isNull);
    });

    test('legacy op with unknown adjustmentKind falls back to default', () {
      final op = EditOperation.create(
        type: EditOpType.adjustmentLayer,
        parameters: const {
          'adjustmentKind': 'someNewKind',
          'visible': true,
          'opacity': 1.0,
        },
      );
      final parsed = AdjustmentLayer.fromOp(op);
      // Unknown names fall through to the default kind.
      expect(parsed.adjustmentKind, AdjustmentKind.backgroundRemoval);
    });

    test('portraitSmooth kind round-trips through EditOperation', () {
      const source = AdjustmentLayer(
        id: 'p-1',
        adjustmentKind: AdjustmentKind.portraitSmooth,
        opacity: 0.6,
      );
      final op = EditOperation.create(
        type: EditOpType.adjustmentLayer,
        parameters: source.toParams(),
      ).copyWith(id: 'p-1');
      final parsed = AdjustmentLayer.fromOp(op);
      expect(parsed.id, 'p-1');
      expect(parsed.adjustmentKind, AdjustmentKind.portraitSmooth);
      expect(parsed.opacity, 0.6);
    });

    test('portraitSmooth has its own displayLabel', () {
      const layer = AdjustmentLayer(
        id: 'p',
        adjustmentKind: AdjustmentKind.portraitSmooth,
      );
      expect(layer.displayLabel, 'Portrait smoothed');
    });

    test('eyeBrighten kind round-trips through EditOperation', () {
      const source = AdjustmentLayer(
        id: 'e-1',
        adjustmentKind: AdjustmentKind.eyeBrighten,
        opacity: 0.8,
      );
      final op = EditOperation.create(
        type: EditOpType.adjustmentLayer,
        parameters: source.toParams(),
      ).copyWith(id: 'e-1');
      final parsed = AdjustmentLayer.fromOp(op);
      expect(parsed.id, 'e-1');
      expect(parsed.adjustmentKind, AdjustmentKind.eyeBrighten);
      expect(parsed.opacity, 0.8);
      expect(parsed.displayLabel, 'Eyes brightened');
    });

    test('teethWhiten kind round-trips through EditOperation', () {
      const source = AdjustmentLayer(
        id: 't-1',
        adjustmentKind: AdjustmentKind.teethWhiten,
      );
      final op = EditOperation.create(
        type: EditOpType.adjustmentLayer,
        parameters: source.toParams(),
      ).copyWith(id: 't-1');
      final parsed = AdjustmentLayer.fromOp(op);
      expect(parsed.id, 't-1');
      expect(parsed.adjustmentKind, AdjustmentKind.teethWhiten);
      expect(parsed.displayLabel, 'Teeth whitened');
    });

    test('AdjustmentKindX.label covers every enum value', () {
      // Future-proof guard: if we add a new kind without a label
      // case the switch falls off the end and the test fires.
      for (final k in AdjustmentKind.values) {
        expect(k.label.isNotEmpty, true,
            reason: 'no label for ${k.name}');
      }
    });

    test('displayLabel covers every enum value', () {
      for (final k in AdjustmentKind.values) {
        final layer = AdjustmentLayer(id: 'x', adjustmentKind: k);
        expect(layer.displayLabel.isNotEmpty, true,
            reason: 'no displayLabel for ${k.name}');
      }
    });

    test('AdjustmentKindX.fromName recognizes every kind', () {
      for (final k in AdjustmentKind.values) {
        expect(AdjustmentKindX.fromName(k.name), k);
      }
    });

    test('AdjustmentKind enum has the 10 expected values in order', () {
      // Guards against accidental reordering that would break
      // persisted pipeline JSON (index-based serialization is not
      // used today, but the order still shows up in analytics +
      // diagnostics and we don't want silent drift).
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
      ]);
    });

    test('faceReshape kind round-trips through EditOperation', () {
      const source = AdjustmentLayer(
        id: 'r-1',
        adjustmentKind: AdjustmentKind.faceReshape,
        reshapeParams: {'slim': 0.3, 'eyes': 0.15},
      );
      final op = EditOperation.create(
        type: EditOpType.adjustmentLayer,
        parameters: source.toParams(),
      ).copyWith(id: 'r-1');
      final parsed = AdjustmentLayer.fromOp(op);
      expect(parsed.id, 'r-1');
      expect(parsed.adjustmentKind, AdjustmentKind.faceReshape);
      expect(parsed.displayLabel, 'Face sculpted');
      expect(parsed.reshapeParams, isNotNull);
      expect(parsed.reshapeParams!['slim'], closeTo(0.3, 1e-9));
      expect(parsed.reshapeParams!['eyes'], closeTo(0.15, 1e-9));
    });

    test('reshapeParams are omitted from params when null', () {
      const source = AdjustmentLayer(
        id: 'no-params',
        adjustmentKind: AdjustmentKind.backgroundRemoval,
      );
      final params = source.toParams();
      expect(params.containsKey('reshapeParams'), false,
          reason: 'bg removal has no reshape params');
    });

    test('copyWith reshapeParams uses sentinel to allow clearing', () {
      const layer = AdjustmentLayer(
        id: 'r',
        adjustmentKind: AdjustmentKind.faceReshape,
        reshapeParams: {'slim': 0.5},
      );
      // Default copyWith preserves the params.
      final preserved = layer.copyWith(opacity: 0.5);
      expect(preserved.reshapeParams, isNotNull);
      expect(preserved.reshapeParams!['slim'], 0.5);
      // Explicit null clears them.
      final cleared = layer.copyWith(reshapeParams: null);
      expect(cleared.reshapeParams, isNull);
    });

    test('malformed reshapeParams in JSON falls back to null', () {
      // Simulate a corrupt pipeline JSON where reshapeParams is
      // something bogus (e.g. a list). Parser should ignore it,
      // NOT crash.
      final op = EditOperation.create(
        type: EditOpType.adjustmentLayer,
        parameters: const {
          'adjustmentKind': 'faceReshape',
          'reshapeParams': 'not a map',
          'visible': true,
          'opacity': 1.0,
        },
      );
      final parsed = AdjustmentLayer.fromOp(op);
      expect(parsed.adjustmentKind, AdjustmentKind.faceReshape);
      expect(parsed.reshapeParams, isNull);
    });

    test('skyReplace kind round-trips skyPresetName', () {
      const source = AdjustmentLayer(
        id: 's-1',
        adjustmentKind: AdjustmentKind.skyReplace,
        skyPresetName: 'sunset',
      );
      final op = EditOperation.create(
        type: EditOpType.adjustmentLayer,
        parameters: source.toParams(),
      ).copyWith(id: 's-1');
      final parsed = AdjustmentLayer.fromOp(op);
      expect(parsed.id, 's-1');
      expect(parsed.adjustmentKind, AdjustmentKind.skyReplace);
      expect(parsed.displayLabel, 'Sky replaced');
      expect(parsed.skyPresetName, 'sunset');
    });

    test('skyPresetName is omitted from params when null', () {
      const source = AdjustmentLayer(
        id: 'no-sky',
        adjustmentKind: AdjustmentKind.backgroundRemoval,
      );
      final params = source.toParams();
      expect(params.containsKey('skyPresetName'), false);
    });

    test('copyWith skyPresetName uses sentinel to allow clearing', () {
      const layer = AdjustmentLayer(
        id: 's',
        adjustmentKind: AdjustmentKind.skyReplace,
        skyPresetName: 'clearBlue',
      );
      // Default copyWith preserves the field.
      final preserved = layer.copyWith(opacity: 0.5);
      expect(preserved.skyPresetName, 'clearBlue');
      // Explicit null clears it.
      final cleared = layer.copyWith(skyPresetName: null);
      expect(cleared.skyPresetName, isNull);
    });

    test('malformed skyPresetName falls back to null', () {
      // Parser must not crash on a non-string value in the JSON.
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

  group('PipelineReaders.contentLayers with AdjustmentLayer', () {
    test('appended AdjustmentLayer is parsed into the layer list', () {
      final op = EditOperation.create(
        type: EditOpType.adjustmentLayer,
        parameters: const AdjustmentLayer(
          id: '',
          adjustmentKind: AdjustmentKind.backgroundRemoval,
        ).toParams(),
      );
      final pipeline =
          EditPipeline.forOriginal('/tmp/img.jpg').append(op);
      final layers = pipeline.contentLayers;
      expect(layers.length, 1);
      expect(layers.first, isA<AdjustmentLayer>());
    });

    test('mixed pipeline: adjustment layer coexists with text', () {
      final pipeline = EditPipeline.forOriginal('/tmp/img.jpg')
          .append(EditOperation.create(
            type: EditOpType.text,
            parameters: const {
              'text': 'Hi',
              'fontSize': 48.0,
              'colorArgb': 0xFFFFFFFF,
            },
          ))
          .append(EditOperation.create(
            type: EditOpType.adjustmentLayer,
            parameters: const AdjustmentLayer(
              id: '',
              adjustmentKind: AdjustmentKind.backgroundRemoval,
            ).toParams(),
          ));
      final layers = pipeline.contentLayers;
      expect(layers.length, 2);
      expect(layers[0], isA<TextLayer>());
      expect(layers[1], isA<AdjustmentLayer>());
    });

    test('disabled AdjustmentLayer is still in layer list but invisible',
        () {
      var pipeline = EditPipeline.forOriginal('/tmp/img.jpg').append(
        EditOperation.create(
          type: EditOpType.adjustmentLayer,
          parameters: const AdjustmentLayer(
            id: '',
            adjustmentKind: AdjustmentKind.backgroundRemoval,
          ).toParams(),
        ),
      );
      final id = pipeline.operations.first.id;
      pipeline = pipeline.toggleEnabled(id);
      final layers = pipeline.contentLayers;
      expect(layers.length, 1);
      expect(layers.first.visible, false);
    });
  });
}
