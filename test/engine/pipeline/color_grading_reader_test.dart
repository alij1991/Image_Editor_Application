import 'package:flutter_test/flutter_test.dart';

import 'package:image_editor/engine/pipeline/edit_op_type.dart';
import 'package:image_editor/engine/pipeline/edit_operation.dart';
import 'package:image_editor/engine/pipeline/edit_pipeline.dart';
import 'package:image_editor/engine/pipeline/op_registry.dart';
import 'package:image_editor/engine/pipeline/pipeline_extensions.dart';

/// Phase XVI.27 — pin the writer ↔ reader contract for the new
/// three-wheel Color Grading op so it can't drift the way gamma did
/// (XVI.22). The panel writes a six-key map to `EditOpType.colorGrading`
/// and the readers below MUST pull each key from the matching name.
///
/// Six readers, six keys:
///   shadowColor -> colorGradingShadowColor
///   midColor    -> colorGradingMidColor
///   highColor   -> colorGradingHighColor
///   globalColor -> colorGradingGlobalColor
///   balance     -> colorGradingBalance
///   blending    -> colorGradingBlending
void main() {
  group('color grading readers (XVI.27)', () {
    test('empty pipeline returns identity for every reader', () {
      final pipeline = EditPipeline.forOriginal('');
      // Default tints are neutral grey; balance is 0; blending is 1
      // (so `op present + colors neutral` is a no-op AND `op absent`
      // matches the same colour state).
      expect(pipeline.colorGradingShadowColor, equals(const [0.5, 0.5, 0.5]));
      expect(pipeline.colorGradingMidColor, equals(const [0.5, 0.5, 0.5]));
      expect(pipeline.colorGradingHighColor, equals(const [0.5, 0.5, 0.5]));
      expect(pipeline.colorGradingGlobalColor, equals(const [0.5, 0.5, 0.5]));
      expect(pipeline.colorGradingBalance, 0.0);
      expect(pipeline.colorGradingBlending, 1.0);
    });

    test('all six map keys are read by the matching getter', () {
      // Mirrors what `ColorGradingPanel._update` writes when the user
      // tweaks every wheel + slider. The values are deliberately
      // distinct so a swap (e.g. mid <-> high) would be caught.
      final op = EditOperation.create(
        type: EditOpType.colorGrading,
        parameters: {
          'shadowColor': const [0.1, 0.2, 0.3],
          'midColor': const [0.4, 0.5, 0.6],
          'highColor': const [0.7, 0.8, 0.9],
          'globalColor': const [0.55, 0.55, 0.55],
          'balance': 0.42,
          'blending': 0.7,
        },
      );
      final pipeline = EditPipeline.forOriginal('').append(op);
      expect(pipeline.colorGradingShadowColor,
          equals(const [0.1, 0.2, 0.3]));
      expect(pipeline.colorGradingMidColor, equals(const [0.4, 0.5, 0.6]));
      expect(pipeline.colorGradingHighColor, equals(const [0.7, 0.8, 0.9]));
      expect(pipeline.colorGradingGlobalColor,
          equals(const [0.55, 0.55, 0.55]));
      expect(pipeline.colorGradingBalance, closeTo(0.42, 1e-9));
      expect(pipeline.colorGradingBlending, closeTo(0.7, 1e-9));
    });

    test('disabled colorGrading op falls back to identity', () {
      final op = EditOperation.create(
        type: EditOpType.colorGrading,
        parameters: {
          'shadowColor': const [0.1, 0.2, 0.3],
          'balance': 0.5,
          'blending': 0.0,
        },
      ).copyWith(enabled: false);
      final pipeline = EditPipeline.forOriginal('').append(op);
      // Disabled op must not leak — every reader returns its identity.
      expect(pipeline.colorGradingShadowColor, equals(const [0.5, 0.5, 0.5]));
      expect(pipeline.colorGradingBalance, 0.0);
      expect(pipeline.colorGradingBlending, 1.0);
    });

    test('OpRegistry classifies colorGrading as shader-pass + replaceable', () {
      // Same shape as splitToning — bespoke panel, no specs, dedicated
      // shader pass. Matrix-composable would be wrong because the maths
      // is band-weighted not a single matrix; preset-replaceable lets a
      // preset wipe the user's colour grade on apply.
      final reg = OpRegistry.forType(EditOpType.colorGrading);
      expect(reg, isNotNull);
      expect(reg!.shaderPass, isTrue);
      expect(reg.presetReplaceable, isTrue);
      expect(reg.matrixComposable, isFalse);
      expect(reg.memento, isFalse);
      // Bespoke panel — no scalar specs.
      expect(reg.specs, isEmpty);
    });

    test('JSON round-trip preserves every key', () {
      // Saved projects survive a reload — the multi-key map is the
      // contract `EditorSession.setMapParams` writes and the JSON layer
      // round-trips verbatim.
      final op = EditOperation.create(
        type: EditOpType.colorGrading,
        parameters: {
          'shadowColor': const [0.1, 0.2, 0.3],
          'midColor': const [0.4, 0.5, 0.6],
          'highColor': const [0.7, 0.8, 0.9],
          'globalColor': const [0.55, 0.55, 0.55],
          'balance': 0.25,
          'blending': 0.85,
        },
      );
      final json = op.toJson();
      final back = EditOperation.fromJson(json);
      expect(back.type, EditOpType.colorGrading);
      expect(back.parameters['shadowColor'], equals(const [0.1, 0.2, 0.3]));
      expect(back.parameters['midColor'], equals(const [0.4, 0.5, 0.6]));
      expect(back.parameters['highColor'], equals(const [0.7, 0.8, 0.9]));
      expect(back.parameters['globalColor'],
          equals(const [0.55, 0.55, 0.55]));
      expect(back.parameters['balance'], closeTo(0.25, 1e-9));
      expect(back.parameters['blending'], closeTo(0.85, 1e-9));
    });
  });
}
