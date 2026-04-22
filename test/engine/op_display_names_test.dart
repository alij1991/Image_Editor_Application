import 'package:flutter_test/flutter_test.dart';

import 'package:image_editor/engine/history/op_display_names.dart';
import 'package:image_editor/engine/pipeline/edit_op_type.dart';
import 'package:image_editor/engine/pipeline/op_spec.dart';

/// X.A.1 — `opDisplayLabel` resolves op-type strings to human-readable
/// labels for undo/redo tooltips + feedback snackbars. Extracted from
/// `editor_page._opLabel` (pre-X.A.1 the lookup was trapped inside a
/// 2000-line UI file).
void main() {
  group('opDisplayLabel', () {
    test('null input → null output', () {
      expect(opDisplayLabel(null), isNull);
    });

    test('slider op routes through OpSpecs.byType(label)', () {
      // Brightness is a registered slider op — the label comes from
      // the OpSpec rather than the hand-rolled switch.
      final spec = OpSpecs.byType(EditOpType.brightness);
      expect(spec, isNotNull);
      expect(opDisplayLabel(EditOpType.brightness), spec!.label);
    });

    test('every matrix-composable slider spec resolves', () {
      for (final spec in OpSpecs.all) {
        if (spec.paramKey != 'value') continue;
        final label = opDisplayLabel(spec.type);
        expect(label, isNotNull,
            reason: 'missing label for slider op ${spec.type}');
        expect(label, spec.label);
      }
    });

    test('AI ops produce dedicated labels', () {
      expect(opDisplayLabel(EditOpType.aiBackgroundRemoval),
          'Remove background');
      expect(opDisplayLabel(EditOpType.aiInpaint), 'Inpaint');
      expect(opDisplayLabel(EditOpType.aiSuperResolution),
          'Super-resolution');
      expect(opDisplayLabel(EditOpType.aiStyleTransfer), 'Style transfer');
      expect(opDisplayLabel(EditOpType.aiFaceBeautify), 'Beautify');
      expect(opDisplayLabel(EditOpType.aiSkyReplace), 'Replace sky');
    });

    test('geometry ops produce their hand-rolled labels', () {
      expect(opDisplayLabel(EditOpType.crop), 'Crop');
      expect(opDisplayLabel(EditOpType.rotate), 'Rotate');
      expect(opDisplayLabel(EditOpType.flip), 'Flip');
      expect(opDisplayLabel(EditOpType.straighten), 'Straighten');
      expect(opDisplayLabel(EditOpType.perspective), 'Perspective');
    });

    test('layer ops produce their hand-rolled labels', () {
      expect(opDisplayLabel(EditOpType.text), 'Text layer');
      expect(opDisplayLabel(EditOpType.sticker), 'Sticker');
      expect(opDisplayLabel(EditOpType.drawing), 'Drawing');
      expect(opDisplayLabel(EditOpType.adjustmentLayer), 'Adjustment');
    });

    test('unknown type falls back to capitalised last segment', () {
      expect(opDisplayLabel('fake.new_op'), 'New_op');
      expect(opDisplayLabel('single'), 'Single');
      expect(opDisplayLabel('a.b.c.deep_tail'), 'Deep_tail');
    });

    test('empty or dot-only string falls through to fallback', () {
      // Last segment is empty → return null to avoid "." or ""
      // tooltips.
      expect(opDisplayLabel('.'), isNull);
      // Empty string after last dot.
      expect(opDisplayLabel('a.'), isNull);
    });

    test('preset.apply alias resolves to "Preset"', () {
      expect(opDisplayLabel('preset.apply'), 'Preset');
    });

    test('lut3d resolves to "LUT"', () {
      expect(opDisplayLabel(EditOpType.lut3d), 'LUT');
    });
  });
}
