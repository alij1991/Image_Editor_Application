import 'package:flutter_test/flutter_test.dart';

import 'package:image_editor/engine/layers/layer_mask.dart';

/// Phase XVI.39 — pin the contract for the new `MaskShape.subject`
/// + `subjectMaskLayerId` field on [LayerMask]:
///   1. The enum carries a fourth value reachable via [MaskShape.values].
///   2. JSON round-trip preserves the new field.
///   3. `cacheKey` includes the layer-id reference and `inverted` so a
///      shader cache can't cross-pollinate two subject masks pointing
///      at different cutouts.
///   4. `copyWith` honours the new field.
void main() {
  group('MaskShape.subject (XVI.39)', () {
    test('enum carries the new value', () {
      expect(MaskShape.values, contains(MaskShape.subject));
      expect(MaskShape.subject.label, 'Subject');
    });

    test('fromName round-trips the new value', () {
      expect(
        MaskShapeX.fromName('subject'),
        MaskShape.subject,
      );
    });

    test('JSON round-trip preserves subjectMaskLayerId', () {
      const original = LayerMask(
        shape: MaskShape.subject,
        subjectMaskLayerId: 'layer-abc-123',
        inverted: true,
      );
      final json = original.toJson();
      expect(json['shape'], 'subject');
      expect(json['subjectMaskLayerId'], 'layer-abc-123');
      expect(json['inverted'], isTrue);

      final back = LayerMask.fromJson(json);
      expect(back.shape, MaskShape.subject);
      expect(back.subjectMaskLayerId, 'layer-abc-123');
      expect(back.inverted, isTrue);
    });

    test('JSON omits subjectMaskLayerId for non-subject shapes', () {
      // Don't write a subjectMaskLayerId key on a linear / radial mask
      // even if the field happens to be set in code — the persisted
      // op is cleaner without it and the reader treats "missing key"
      // as null.
      const linear = LayerMask(
        shape: MaskShape.linear,
        subjectMaskLayerId: 'should-not-appear',
      );
      expect(linear.toJson().containsKey('subjectMaskLayerId'), isFalse);
    });

    test('cacheKey includes the layer id and inverted bit', () {
      const a = LayerMask(
        shape: MaskShape.subject,
        subjectMaskLayerId: 'aaa',
      );
      const b = LayerMask(
        shape: MaskShape.subject,
        subjectMaskLayerId: 'bbb',
      );
      const aInv = LayerMask(
        shape: MaskShape.subject,
        subjectMaskLayerId: 'aaa',
        inverted: true,
      );
      expect(a.cacheKey, isNot(equals(b.cacheKey)));
      expect(a.cacheKey, isNot(equals(aInv.cacheKey)));
      // A null id renders as "_" — distinguishable from any real id.
      const aNull = LayerMask(shape: MaskShape.subject);
      expect(aNull.cacheKey.contains('_'), isTrue);
    });

    test('copyWith honours the new field', () {
      const base = LayerMask(shape: MaskShape.subject);
      final next = base.copyWith(subjectMaskLayerId: 'fresh-id');
      expect(next.shape, MaskShape.subject);
      expect(next.subjectMaskLayerId, 'fresh-id');
    });

    test('isIdentity is false for subject masks', () {
      // Even with no source layer id, a Subject mask is meaningful
      // intent. The painter falls back to identity when the id can't
      // resolve, but the LayerMask itself reports non-identity so
      // the editor sheet keeps showing the chip selected.
      const m = LayerMask(shape: MaskShape.subject);
      expect(m.isIdentity, isFalse);
    });
  });
}
