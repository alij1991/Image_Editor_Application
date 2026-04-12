import '../pipeline/edit_op_type.dart';
import '../pipeline/edit_operation.dart';
import 'preset.dart';

/// Factory for the app's built-in presets.
///
/// Each preset is a curated list of [EditOperation]s that, when applied,
/// reproduce a recognizable photographic look. These use only ops that
/// exist in Phase 5 so presets are reproducible through the parametric
/// pipeline — no baked LUTs yet.
class BuiltInPresets {
  BuiltInPresets._();

  static EditOperation _op(
    String type,
    Map<String, dynamic> params,
  ) =>
      EditOperation.create(type: type, parameters: params);

  static List<Preset> get all => [
        const Preset(
          id: 'builtin.none',
          name: 'Original',
          category: 'Basic',
          builtIn: true,
          operations: [],
        ),
        Preset(
          id: 'builtin.punch',
          name: 'Punch',
          category: 'Basic',
          builtIn: true,
          operations: [
            _op(EditOpType.contrast, {'value': 0.25}),
            _op(EditOpType.saturation, {'value': 0.35}),
            _op(EditOpType.vibrance, {'value': 0.2}),
            _op(EditOpType.shadows, {'value': 0.15}),
            _op(EditOpType.highlights, {'value': -0.2}),
          ],
        ),
        Preset(
          id: 'builtin.mono',
          name: 'Mono',
          category: 'Mono',
          builtIn: true,
          operations: [
            _op(EditOpType.saturation, {'value': -1.0}),
            _op(EditOpType.contrast, {'value': 0.2}),
            _op(EditOpType.vignette, {
              'amount': 0.3,
              'feather': 0.4,
              'roundness': 0.5,
            }),
          ],
        ),
        Preset(
          id: 'builtin.vintage',
          name: 'Vintage',
          category: 'Film',
          builtIn: true,
          operations: [
            _op(EditOpType.temperature, {'value': 0.25}),
            _op(EditOpType.tint, {'value': -0.1}),
            _op(EditOpType.saturation, {'value': -0.25}),
            _op(EditOpType.contrast, {'value': -0.1}),
            _op(EditOpType.shadows, {'value': 0.2}),
            _op(EditOpType.highlights, {'value': -0.25}),
            _op(EditOpType.grain, {'amount': 0.2, 'cellSize': 2.0}),
            _op(EditOpType.vignette, {
              'amount': 0.35,
              'feather': 0.45,
              'roundness': 0.5,
            }),
          ],
        ),
        Preset(
          id: 'builtin.cool_film',
          name: 'Cool Film',
          category: 'Film',
          builtIn: true,
          operations: [
            _op(EditOpType.temperature, {'value': -0.25}),
            _op(EditOpType.tint, {'value': 0.08}),
            _op(EditOpType.saturation, {'value': -0.15}),
            _op(EditOpType.contrast, {'value': 0.1}),
            _op(EditOpType.highlights, {'value': -0.15}),
          ],
        ),
        Preset(
          id: 'builtin.warm_sun',
          name: 'Warm Sun',
          category: 'Portrait',
          builtIn: true,
          operations: [
            _op(EditOpType.temperature, {'value': 0.35}),
            _op(EditOpType.exposure, {'value': 0.3}),
            _op(EditOpType.vibrance, {'value': 0.25}),
            _op(EditOpType.highlights, {'value': -0.1}),
            _op(EditOpType.shadows, {'value': 0.15}),
          ],
        ),
        Preset(
          id: 'builtin.matte',
          name: 'Matte',
          category: 'Film',
          builtIn: true,
          operations: [
            _op(EditOpType.contrast, {'value': -0.2}),
            _op(EditOpType.shadows, {'value': 0.35}),
            _op(EditOpType.blacks, {'value': 0.15}),
            _op(EditOpType.saturation, {'value': -0.1}),
            _op(EditOpType.temperature, {'value': 0.05}),
          ],
        ),
        Preset(
          id: 'builtin.dramatic',
          name: 'Dramatic',
          category: 'Bold',
          builtIn: true,
          operations: [
            _op(EditOpType.contrast, {'value': 0.4}),
            _op(EditOpType.clarity, {'value': 0.4}),
            _op(EditOpType.vibrance, {'value': 0.3}),
            _op(EditOpType.shadows, {'value': -0.15}),
            _op(EditOpType.whites, {'value': 0.2}),
            _op(EditOpType.blacks, {'value': -0.2}),
            _op(EditOpType.vignette, {
              'amount': 0.5,
              'feather': 0.35,
              'roundness': 0.5,
            }),
          ],
        ),
        Preset(
          id: 'builtin.noir',
          name: 'Noir',
          category: 'Mono',
          builtIn: true,
          operations: [
            _op(EditOpType.saturation, {'value': -1.0}),
            _op(EditOpType.contrast, {'value': 0.45}),
            _op(EditOpType.whites, {'value': 0.25}),
            _op(EditOpType.blacks, {'value': -0.35}),
            _op(EditOpType.vignette, {
              'amount': 0.55,
              'feather': 0.3,
              'roundness': 0.5,
            }),
            _op(EditOpType.grain, {'amount': 0.3, 'cellSize': 2.0}),
          ],
        ),
      ];
}
