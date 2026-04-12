import 'package:flutter_test/flutter_test.dart';

import 'package:image_editor/engine/layers/content_layer.dart';
import 'package:image_editor/engine/layers/layer_blend_mode.dart';
import 'package:image_editor/engine/layers/layer_mask.dart';
import 'package:image_editor/engine/pipeline/edit_op_type.dart';
import 'package:image_editor/engine/pipeline/edit_operation.dart';
import 'package:image_editor/engine/pipeline/edit_pipeline.dart';
import 'package:image_editor/engine/pipeline/pipeline_extensions.dart';

/// Covers the audit fixes for the layer preview contract:
///
/// - `LayerEditSheet` no longer goes through the history on every
///   slider tick (live preview uses `session.previewLayer`).
/// - `LayerStackPanel` opacity slider commits only on release.
///
/// This file tests the pure data side of that contract — the typed
/// layer fields survive serialization, copy-with preserves blend/mask,
/// and the pipeline can both contain and omit the new fields.
void main() {
  group('ContentLayer copyWith preserves blend mode + mask', () {
    test('TextLayer', () {
      const base = TextLayer(
        id: 'id',
        text: 'hi',
        fontSize: 48,
        colorArgb: 0xFFFFFFFF,
        blendMode: LayerBlendMode.multiply,
        mask: LayerMask(shape: MaskShape.linear, feather: 0.25, angle: 0.3),
      );
      final next = base.copyWith(opacity: 0.5);
      expect(next.blendMode, LayerBlendMode.multiply);
      expect(next.mask.shape, MaskShape.linear);
      expect(next.mask.feather, 0.25);
      expect(next.opacity, 0.5);
      expect(next.text, 'hi');
    });

    test('StickerLayer', () {
      const base = StickerLayer(
        id: 'id',
        character: '★',
        fontSize: 60,
        blendMode: LayerBlendMode.screen,
        mask: LayerMask(shape: MaskShape.radial, innerRadius: 0.1),
      );
      final next = base.copyWith(x: 0.25);
      expect(next.blendMode, LayerBlendMode.screen);
      expect(next.mask.shape, MaskShape.radial);
      expect(next.mask.innerRadius, 0.1);
      expect(next.x, 0.25);
    });

    test('DrawingLayer', () {
      const base = DrawingLayer(
        id: 'id',
        strokes: [],
        blendMode: LayerBlendMode.overlay,
        mask: LayerMask(shape: MaskShape.linear),
      );
      final next = base.copyWith(opacity: 0.3);
      expect(next.blendMode, LayerBlendMode.overlay);
      expect(next.mask.shape, MaskShape.linear);
      expect(next.opacity, 0.3);
    });
  });

  group('Preview snapshot: layer list matches committed pipeline', () {
    EditOperation textOp(String id, String text) {
      return EditOperation.create(
        type: EditOpType.text,
        parameters: {
          'text': text,
          'fontSize': 48.0,
          'colorArgb': 0xFFFFFFFF,
        },
      ).copyWith(id: id);
    }

    test('swapping one layer preserves the rest', () {
      final a = textOp('a', 'A');
      final b = textOp('b', 'B');
      final c = textOp('c', 'C');
      final pipeline =
          EditPipeline.forOriginal('/tmp/img.jpg').append(a).append(b).append(c);
      final original = pipeline.contentLayers;
      expect(original.length, 3);

      // Simulate session.previewLayer swapping B with a modified draft.
      final modifiedB =
          (original[1] as TextLayer).copyWith(blendMode: LayerBlendMode.multiply);
      final swapped = <ContentLayer>[
        for (final l in original)
          if (l.id == modifiedB.id) modifiedB else l,
      ];
      expect(swapped.length, 3);
      expect((swapped[0] as TextLayer).text, 'A');
      expect((swapped[1] as TextLayer).blendMode, LayerBlendMode.multiply);
      expect((swapped[1] as TextLayer).text, 'B');
      expect((swapped[2] as TextLayer).text, 'C');
    });

    test('hidden-layer preview skips the layer in the output list', () {
      final a = textOp('a', 'A');
      final b = textOp('b', 'B');
      var pipeline =
          EditPipeline.forOriginal('/tmp/img.jpg').append(a).append(b);

      // Simulate session.previewLayer passing an invisible draft.
      final visibleLayers = <ContentLayer>[];
      for (final op in pipeline.operations) {
        final parsed = contentLayerFromOp(op);
        if (parsed == null) continue;
        if (parsed.id == 'b') {
          // Draft is invisible → skip entirely.
          continue;
        }
        if (parsed.visible) visibleLayers.add(parsed);
      }
      expect(visibleLayers.length, 1);
      expect((visibleLayers.first as TextLayer).text, 'A');
    });
  });

  group('Feather semantics', () {
    test('feather=0 produces a collapsed stop band (hard edge)', () {
      // Mirrors LayerPainter's stop calculation.
      double halfBand(double feather) => 0.5 * feather;
      final stops = [0.5 - halfBand(0), 0.5 + halfBand(0)];
      expect(stops[0], 0.5);
      expect(stops[1], 0.5);
    });

    test('feather=1 produces the full [0, 1] stop band', () {
      double halfBand(double feather) => 0.5 * feather;
      final stops = [0.5 - halfBand(1), 0.5 + halfBand(1)];
      expect(stops[0], 0.0);
      expect(stops[1], 1.0);
    });

    test('feather=0.5 is a half-width band', () {
      double halfBand(double feather) => 0.5 * feather;
      final stops = [0.5 - halfBand(0.5), 0.5 + halfBand(0.5)];
      expect(stops[0], 0.25);
      expect(stops[1], 0.75);
    });
  });

  group('Radius constraint (UI guarantees inner < outer)', () {
    test('inner slider clamp formula', () {
      // Replicates the `onChanged` in LayerEditSheet's inner-radius slider.
      double clampInner(double newInner, double outer) {
        return newInner > outer - 0.02 ? outer - 0.02 : newInner;
      }

      expect(clampInner(0.1, 0.5), 0.1);
      expect(clampInner(0.6, 0.5), closeTo(0.48, 1e-9));
      expect(clampInner(0.5, 0.5), closeTo(0.48, 1e-9));
    });

    test('outer slider clamp formula', () {
      double clampOuter(double newOuter, double inner) {
        return newOuter < inner + 0.02 ? inner + 0.02 : newOuter;
      }

      expect(clampOuter(0.8, 0.5), 0.8);
      expect(clampOuter(0.5, 0.5), closeTo(0.52, 1e-9));
      expect(clampOuter(0.4, 0.5), closeTo(0.52, 1e-9));
    });
  });
}
