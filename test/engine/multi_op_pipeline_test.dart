import 'package:flutter_test/flutter_test.dart';

import 'package:image_editor/engine/pipeline/edit_op_type.dart';
import 'package:image_editor/engine/pipeline/edit_operation.dart';
import 'package:image_editor/engine/pipeline/edit_pipeline.dart';
import 'package:image_editor/engine/pipeline/matrix_composer.dart';
import 'package:image_editor/engine/pipeline/pipeline_extensions.dart';

EditOperation _op(String type, Map<String, dynamic> params) =>
    EditOperation.create(type: type, parameters: params);

void main() {
  group('PipelineReaders multi-op', () {
    test('reads every adjustment value', () {
      final p = EditPipeline.forOriginal('/tmp/img.jpg')
          .append(_op(EditOpType.brightness, {'value': 0.10}))
          .append(_op(EditOpType.contrast, {'value': 0.20}))
          .append(_op(EditOpType.exposure, {'value': 0.30}))
          .append(_op(EditOpType.highlights, {'value': -0.40}))
          .append(_op(EditOpType.shadows, {'value': 0.50}))
          .append(_op(EditOpType.whites, {'value': -0.10}))
          .append(_op(EditOpType.blacks, {'value': 0.15}))
          .append(_op(EditOpType.temperature, {'value': 0.25}))
          .append(_op(EditOpType.tint, {'value': -0.05}))
          .append(_op(EditOpType.saturation, {'value': 0.70}))
          .append(_op(EditOpType.vibrance, {'value': 0.35}))
          .append(_op(EditOpType.hue, {'value': 45}))
          .append(_op(EditOpType.dehaze, {'value': 0.22}))
          .append(_op(EditOpType.clarity, {'value': 0.60}));

      expect(p.brightnessValue, 0.10);
      expect(p.contrastValue, 0.20);
      expect(p.exposureValue, 0.30);
      expect(p.highlightsValue, -0.40);
      expect(p.shadowsValue, 0.50);
      expect(p.whitesValue, -0.10);
      expect(p.blacksValue, 0.15);
      expect(p.temperatureValue, 0.25);
      expect(p.tintValue, -0.05);
      expect(p.saturationValue, 0.70);
      expect(p.vibranceValue, 0.35);
      expect(p.hueValue, 45);
      expect(p.dehazeValue, 0.22);
      expect(p.clarityValue, 0.60);
    });

    test('hasEnabledOp finds present ops', () {
      final p = EditPipeline.forOriginal('/tmp/img.jpg')
          .append(_op(EditOpType.brightness, {'value': 0.1}));
      expect(p.hasEnabledOp(EditOpType.brightness), true);
      expect(p.hasEnabledOp(EditOpType.contrast), false);
    });

    test('disabled ops are ignored by hasEnabledOp', () {
      var p = EditPipeline.forOriginal('/tmp/img.jpg')
          .append(_op(EditOpType.brightness, {'value': 0.1}));
      expect(p.hasEnabledOp(EditOpType.brightness), true);
      p = p.toggleEnabled(p.operations.first.id);
      expect(p.hasEnabledOp(EditOpType.brightness), false);
    });

    test('findOp returns the first enabled op of the type', () {
      final p = EditPipeline.forOriginal('/tmp/img.jpg')
          .append(_op(EditOpType.brightness, {'value': 0.1}));
      final found = p.findOp(EditOpType.brightness);
      expect(found, isNotNull);
      expect(found!.parameters['value'], 0.1);
    });
  });

  group('MatrixComposer multi-op', () {
    const MatrixComposer composer = MatrixComposer();

    test('brightness + contrast compose to a single matrix', () {
      final p = EditPipeline.forOriginal('/tmp/img.jpg')
          .append(_op(EditOpType.brightness, {'value': 0.2}))
          .append(_op(EditOpType.contrast, {'value': 0.1}));
      final m = composer.compose(p);
      expect(m.length, 20);
      // Identity diagonal stays close to 1 after a mild contrast boost.
      expect(m[0], closeTo(1.1, 1e-4));
      expect(m[6], closeTo(1.1, 1e-4));
      expect(m[12], closeTo(1.1, 1e-4));
      // Brightness bias + contrast bias combine.
      const expectedBias = 0.2 * 1.1 + (0.5 * (1 - 1.1));
      expect(m[4], closeTo(expectedBias, 1e-4));
    });

    test('disabled ops do not contribute', () {
      var p = EditPipeline.forOriginal('/tmp/img.jpg')
          .append(_op(EditOpType.brightness, {'value': 0.5}));
      p = p.toggleEnabled(p.operations.first.id);
      final m = composer.compose(p);
      final identity = MatrixComposer.identity();
      for (int i = 0; i < 20; i++) {
        expect(m[i], closeTo(identity[i], 1e-6), reason: 'i=$i');
      }
    });
  });
}
