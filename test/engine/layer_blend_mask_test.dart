import 'dart:ui' show BlendMode;

import 'package:flutter_test/flutter_test.dart';

import 'package:image_editor/engine/layers/content_layer.dart';
import 'package:image_editor/engine/layers/layer_blend_mode.dart';
import 'package:image_editor/engine/layers/layer_mask.dart';
import 'package:image_editor/engine/pipeline/edit_op_type.dart';
import 'package:image_editor/engine/pipeline/edit_operation.dart';

void main() {
  group('LayerBlendMode', () {
    test('every enum value maps to a Flutter BlendMode', () {
      for (final mode in LayerBlendMode.values) {
        expect(mode.flutter, isA<BlendMode>());
      }
    });

    test('normal maps to srcOver', () {
      expect(LayerBlendMode.normal.flutter, BlendMode.srcOver);
    });

    test('every enum value has a label', () {
      for (final mode in LayerBlendMode.values) {
        expect(mode.label, isNotEmpty);
      }
    });

    test('fromName round-trips valid names', () {
      for (final mode in LayerBlendMode.values) {
        expect(LayerBlendModeX.fromName(mode.name), mode);
      }
    });

    test('fromName falls back to normal for unknown / null names', () {
      expect(LayerBlendModeX.fromName(null), LayerBlendMode.normal);
      expect(LayerBlendModeX.fromName(''), LayerBlendMode.normal);
      expect(LayerBlendModeX.fromName('bogus-mode'), LayerBlendMode.normal);
    });
  });

  group('LayerMask', () {
    test('LayerMask.none is identity', () {
      expect(LayerMask.none.isIdentity, true);
      expect(LayerMask.none.shape, MaskShape.none);
    });

    test('copyWith preserves siblings', () {
      const m = LayerMask(
        shape: MaskShape.radial,
        inverted: true,
        feather: 0.3,
        cx: 0.25,
        cy: 0.75,
        innerRadius: 0.1,
        outerRadius: 0.4,
      );
      final next = m.copyWith(feather: 0.5);
      expect(next.shape, MaskShape.radial);
      expect(next.inverted, true);
      expect(next.feather, 0.5);
      expect(next.cx, 0.25);
      expect(next.cy, 0.75);
      expect(next.innerRadius, 0.1);
      expect(next.outerRadius, 0.4);
    });

    test('JSON roundtrip for linear mask', () {
      const src = LayerMask(
        shape: MaskShape.linear,
        inverted: false,
        feather: 0.25,
        cx: 0.5,
        cy: 0.5,
        angle: 1.2,
      );
      final parsed = LayerMask.fromJson(src.toJson());
      expect(parsed.shape, MaskShape.linear);
      expect(parsed.feather, 0.25);
      expect(parsed.cx, 0.5);
      expect(parsed.cy, 0.5);
      expect(parsed.angle, 1.2);
    });

    test('JSON roundtrip for radial mask', () {
      const src = LayerMask(
        shape: MaskShape.radial,
        inverted: true,
        feather: 0.4,
        cx: 0.3,
        cy: 0.7,
        innerRadius: 0.15,
        outerRadius: 0.55,
      );
      final parsed = LayerMask.fromJson(src.toJson());
      expect(parsed.shape, MaskShape.radial);
      expect(parsed.inverted, true);
      expect(parsed.innerRadius, 0.15);
      expect(parsed.outerRadius, 0.55);
    });

    test('fromJson(null) returns none', () {
      expect(LayerMask.fromJson(null), LayerMask.none);
    });

    test('linearEndpoints produces finite coordinates', () {
      const m = LayerMask(shape: MaskShape.linear, angle: 0.5);
      final (start, end) = m.linearEndpoints();
      expect(start.x.isFinite, true);
      expect(start.y.isFinite, true);
      expect(end.x.isFinite, true);
      expect(end.y.isFinite, true);
    });
  });

  group('ContentLayer blend/mask round-trip', () {
    test('TextLayer default layers have normal blend + no mask', () {
      const t = TextLayer(
        id: 'id',
        text: 'hi',
        fontSize: 48,
        colorArgb: 0xFFFFFFFF,
      );
      expect(t.blendMode, LayerBlendMode.normal);
      expect(t.mask.isIdentity, true);
    });

    test('TextLayer round-trip preserves blend mode + linear mask', () {
      const source = TextLayer(
        id: 'id-1',
        text: 'hello',
        fontSize: 48,
        colorArgb: 0xFFFFFFFF,
        blendMode: LayerBlendMode.multiply,
        mask: LayerMask(
          shape: MaskShape.linear,
          feather: 0.3,
          cx: 0.5,
          cy: 0.5,
          angle: 0.5,
        ),
      );
      final op = EditOperation.create(
        type: EditOpType.text,
        parameters: source.toParams(),
      ).copyWith(id: 'id-1');
      final parsed = TextLayer.fromOp(op);
      expect(parsed.blendMode, LayerBlendMode.multiply);
      expect(parsed.mask.shape, MaskShape.linear);
      expect(parsed.mask.feather, 0.3);
      expect(parsed.mask.angle, 0.5);
    });

    test('StickerLayer round-trip preserves radial mask', () {
      const source = StickerLayer(
        id: 'id-2',
        character: '🎉',
        fontSize: 80,
        blendMode: LayerBlendMode.screen,
        mask: LayerMask(
          shape: MaskShape.radial,
          innerRadius: 0.2,
          outerRadius: 0.6,
          inverted: true,
        ),
      );
      final op = EditOperation.create(
        type: EditOpType.sticker,
        parameters: source.toParams(),
      ).copyWith(id: 'id-2');
      final parsed = StickerLayer.fromOp(op);
      expect(parsed.blendMode, LayerBlendMode.screen);
      expect(parsed.mask.shape, MaskShape.radial);
      expect(parsed.mask.innerRadius, 0.2);
      expect(parsed.mask.outerRadius, 0.6);
      expect(parsed.mask.inverted, true);
    });

    test('DrawingLayer round-trip preserves blend mode', () {
      const source = DrawingLayer(
        id: 'id-3',
        strokes: [],
        blendMode: LayerBlendMode.overlay,
      );
      final op = EditOperation.create(
        type: EditOpType.drawing,
        parameters: source.toParams(),
      ).copyWith(id: 'id-3');
      final parsed = DrawingLayer.fromOp(op);
      expect(parsed.blendMode, LayerBlendMode.overlay);
    });

    test('legacy ops without blendMode/mask fields parse as defaults', () {
      // Simulate a pipeline saved BEFORE Phase 8 where layer ops had
      // no blendMode/mask keys.
      final op = EditOperation.create(
        type: EditOpType.text,
        parameters: const {
          'text': 'legacy',
          'fontSize': 48.0,
          'colorArgb': 0xFFFFFFFF,
          'x': 0.5,
          'y': 0.5,
          'rotation': 0.0,
          'scale': 1.0,
          'opacity': 1.0,
          'visible': true,
        },
      );
      final parsed = TextLayer.fromOp(op);
      expect(parsed.blendMode, LayerBlendMode.normal);
      expect(parsed.mask.isIdentity, true);
    });

    test('toParams omits blendMode + mask when defaults (smaller JSON)', () {
      const layer = TextLayer(
        id: 'id',
        text: 'hi',
        fontSize: 32,
        colorArgb: 0xFFFFFFFF,
      );
      final params = layer.toParams();
      expect(params.containsKey('blendMode'), false);
      expect(params.containsKey('mask'), false);
    });

    test('toParams includes blendMode when non-default', () {
      const layer = TextLayer(
        id: 'id',
        text: 'hi',
        fontSize: 32,
        colorArgb: 0xFFFFFFFF,
        blendMode: LayerBlendMode.multiply,
      );
      final params = layer.toParams();
      expect(params['blendMode'], 'multiply');
    });
  });
}
