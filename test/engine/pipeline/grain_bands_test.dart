import 'package:flutter_test/flutter_test.dart';

import 'package:image_editor/engine/pipeline/edit_op_type.dart';
import 'package:image_editor/engine/pipeline/edit_operation.dart';
import 'package:image_editor/engine/pipeline/edit_pipeline.dart';
import 'package:image_editor/engine/pipeline/op_registry.dart';
import 'package:image_editor/engine/pipeline/op_spec.dart';
import 'package:image_editor/engine/pipeline/pipeline_extensions.dart';

/// Phase XVI.34 — pin the OpSpec ↔ shader contract for the new
/// luminance-banded grain so the writer (slider) and reader
/// (`pass_builders.dart::_grainPass`) can't drift the way XVI.22
/// found gamma had drifted.
///
/// Three new param keys ('shadows' / 'mids' / 'highs') each with
/// identity 1.0 — default state is uniform grain, matching pre-
/// XVI.34 behaviour exactly so legacy ops migrate seamlessly.
void main() {
  group('grain band OpSpecs (XVI.34)', () {
    test('three new specs with identity=1 + group="Bands"', () {
      final specs = OpSpecs.paramsForType(EditOpType.grain);
      final byKey = {for (final s in specs) s.paramKey: s};

      // Pre-XVI.34 specs still present
      expect(byKey.containsKey('amount'), isTrue);
      expect(byKey.containsKey('cellSize'), isTrue);

      // XVI.34 additions — all three keyed by their audit-prescribed
      // names ('shadows' / 'mids' / 'highs'), each with identity 1.0
      // so a fresh op or a legacy op without these keys reads as
      // "no banding modulation".
      expect(byKey.containsKey('shadows'), isTrue,
          reason: 'shadows spec missing — slider would have no UI');
      expect(byKey.containsKey('mids'), isTrue,
          reason: 'mids spec missing');
      expect(byKey.containsKey('highs'), isTrue,
          reason: 'highs spec missing');

      for (final key in const ['shadows', 'mids', 'highs']) {
        final spec = byKey[key]!;
        expect(spec.identity, 1.0, reason: '$key identity must be 1.0');
        expect(spec.min, 0.0);
        expect(spec.max, 1.0);
        expect(spec.group, 'Bands');
        expect(spec.category, OpCategory.effects);
      }
    });

    test('interpolatingKeys covers all four magnitudes', () {
      // Phase III.3 contract: every preset-amount-interpolating param
      // must be declared in interpolatingKeys, otherwise the preset
      // Amount slider silently does nothing for that param.
      final reg = OpRegistry.forType(EditOpType.grain);
      expect(reg, isNotNull);
      expect(reg!.interpolatingKeys, equals({'amount', 'shadows', 'mids', 'highs'}));
    });
  });

  group('grain band readers (XVI.34)', () {
    test('legacy op (no band keys) reads back as identity-1 across all bands',
        () {
      // The wire-level invariant: a pre-XVI.34 op only carries
      // `amount` + `cellSize`; the pass builder reads `shadows` /
      // `mids` / `highs` with default 1.0 so the rendered grain is
      // identical to the uniform pre-XVI.34 result.
      final op = EditOperation.create(
        type: EditOpType.grain,
        parameters: {'amount': 0.5, 'cellSize': 3.0},
      );
      final pipeline = EditPipeline.forOriginal('').append(op);

      expect(pipeline.readParam(EditOpType.grain, 'shadows', 1.0), 1.0);
      expect(pipeline.readParam(EditOpType.grain, 'mids', 1.0), 1.0);
      expect(pipeline.readParam(EditOpType.grain, 'highs', 1.0), 1.0);
    });

    test('written band values round-trip through the pipeline reader', () {
      // Mirrors what LightroomPanel writes when the user pulls each
      // band slider. The values are deliberately distinct so a swap
      // (e.g. shadows ↔ highs) would surface here.
      final op = EditOperation.create(
        type: EditOpType.grain,
        parameters: {
          'amount': 0.6,
          'cellSize': 2.0,
          'shadows': 0.8,
          'mids': 0.4,
          'highs': 0.1,
        },
      );
      final pipeline = EditPipeline.forOriginal('').append(op);
      expect(pipeline.readParam(EditOpType.grain, 'shadows', 1.0), 0.8);
      expect(pipeline.readParam(EditOpType.grain, 'mids', 1.0), 0.4);
      expect(pipeline.readParam(EditOpType.grain, 'highs', 1.0), 0.1);
    });

    test('disabled grain op falls back to identity for every band', () {
      final op = EditOperation.create(
        type: EditOpType.grain,
        parameters: {'amount': 0.5, 'shadows': 0.0, 'mids': 0.0, 'highs': 0.0},
      ).copyWith(enabled: false);
      final pipeline = EditPipeline.forOriginal('').append(op);
      // readParam falls through past disabled ops, so we get the
      // caller's default — 1.0 for the band readers.
      expect(pipeline.readParam(EditOpType.grain, 'shadows', 1.0), 1.0);
      expect(pipeline.readParam(EditOpType.grain, 'mids', 1.0), 1.0);
      expect(pipeline.readParam(EditOpType.grain, 'highs', 1.0), 1.0);
    });
  });
}
