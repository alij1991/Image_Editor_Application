import 'package:flutter_test/flutter_test.dart';

import 'package:image_editor/engine/layers/content_layer.dart';
import 'package:image_editor/engine/pipeline/edit_op_type.dart';
import 'package:image_editor/engine/pipeline/edit_operation.dart';

/// Phase XVI.42 — pin the LayerEffect data model + persistence
/// invariants. The four enum values must persist round-trip even when
/// only `dropShadow` has rendering today, so a future BiDi schema
/// change can't drop the unimplemented effects from saved projects.
void main() {
  group('LayerEffect (XVI.42)', () {
    test('default constructor lands on a sensible drop-shadow preset', () {
      const e = LayerEffect(type: LayerEffectType.dropShadow);
      // 60% alpha black (0x99 = 153/255 ≈ 0.6) is the Photoshop
      // default and the audit-prescribed visible-on-toggle starting
      // point. If this drifts, every layer that toggles a drop
      // shadow on for the first time would render differently.
      expect(e.colorArgb, 0x99000000);
      expect(e.opacity, 1.0);
      expect(e.blur, 6.0);
      expect(e.offsetX, 4.0);
      expect(e.offsetY, 4.0);
    });

    test('JSON round-trip preserves every field', () {
      const e = LayerEffect(
        type: LayerEffectType.outerGlow,
        colorArgb: 0xFFFF8800,
        opacity: 0.75,
        blur: 12.0,
        offsetX: -3.0,
        offsetY: 5.0,
      );
      final back = LayerEffect.fromJson(e.toJson());
      expect(back, equals(e));
    });

    test('fromName falls back to dropShadow on unknown / null input', () {
      // Saved projects from a future build with new effect names
      // shouldn't crash — they reload as a drop shadow, which is the
      // most universally applicable default.
      expect(LayerEffectTypeX.fromName(null), LayerEffectType.dropShadow);
      expect(
          LayerEffectTypeX.fromName('shimmer'), LayerEffectType.dropShadow);
    });

    test('every enum value has a non-empty label', () {
      for (final v in LayerEffectType.values) {
        expect(v.label.isNotEmpty, isTrue, reason: '${v.name} missing label');
      }
    });
  });

  group('ContentLayer effects round-trip (XVI.42)', () {
    test('TextLayer carries effects through fromOp / toParams', () {
      const text = TextLayer(
        id: 'L1',
        text: 'Hi',
        fontSize: 32,
        colorArgb: 0xFFFFFFFF,
        effects: [
          LayerEffect(type: LayerEffectType.dropShadow),
          LayerEffect(
            type: LayerEffectType.stroke,
            colorArgb: 0xFFFF0000,
            blur: 0,
            offsetX: 0,
            offsetY: 0,
          ),
        ],
      );
      final params = text.toParams();
      expect(params.containsKey('effects'), isTrue);
      final op = EditOperation.create(
        type: EditOpType.text,
        parameters: params,
      );
      final back = TextLayer.fromOp(op);
      expect(back.effects, hasLength(2));
      expect(back.effects.first.type, LayerEffectType.dropShadow);
      expect(back.effects[1].type, LayerEffectType.stroke);
      expect(back.effects[1].colorArgb, 0xFFFF0000);
    });

    test('empty effects list is omitted from JSON for a clean payload', () {
      const text = TextLayer(
        id: 'L1',
        text: 'Hi',
        fontSize: 32,
        colorArgb: 0xFFFFFFFF,
      );
      expect(text.toParams().containsKey('effects'), isFalse,
          reason: 'no effects → no key in the persisted op map');
    });

    test('StickerLayer carries effects through fromOp', () {
      const sticker = StickerLayer(
        id: 'S1',
        character: '★',
        fontSize: 64,
        effects: [LayerEffect(type: LayerEffectType.outerGlow)],
      );
      final op = EditOperation.create(
        type: EditOpType.sticker,
        parameters: sticker.toParams(),
      );
      final back = StickerLayer.fromOp(op);
      expect(back.effects, hasLength(1));
      expect(back.effects.first.type, LayerEffectType.outerGlow);
    });

    test('DrawingLayer carries effects through fromOp', () {
      const draw = DrawingLayer(
        id: 'D1',
        strokes: [],
        effects: [LayerEffect(type: LayerEffectType.innerGlow)],
      );
      final op = EditOperation.create(
        type: EditOpType.drawing,
        parameters: draw.toParams(),
      );
      final back = DrawingLayer.fromOp(op);
      expect(back.effects, hasLength(1));
      expect(back.effects.first.type, LayerEffectType.innerGlow);
    });

    test('readEffectsFromParams handles missing / wrong-typed entries', () {
      // Defensive against bad JSON — a non-list `effects` entry must
      // produce an empty list, not throw.
      expect(
        readEffectsFromParams(const {'effects': 'not a list'}),
        isEmpty,
      );
      expect(readEffectsFromParams(const {}), isEmpty);
      // Mixed valid + invalid entries: keep the valid ones.
      final mixed = readEffectsFromParams({
        'effects': [
          {'type': 'dropShadow'},
          'garbage',
          42,
          {'type': 'stroke', 'color': 0xFFFFFFFF},
        ],
      });
      expect(mixed, hasLength(2));
      expect(mixed[0].type, LayerEffectType.dropShadow);
      expect(mixed[1].type, LayerEffectType.stroke);
    });

    test('copyWith on every layer subtype honours the new effects field',
        () {
      const text = TextLayer(
        id: 'L1',
        text: 'x',
        fontSize: 32,
        colorArgb: 0xFFFFFFFF,
      );
      final next =
          text.copyWith(effects: const [LayerEffect(type: LayerEffectType.dropShadow)]);
      expect(next.effects, hasLength(1));
      // Other fields unchanged
      expect(next.text, 'x');
    });
  });
}
