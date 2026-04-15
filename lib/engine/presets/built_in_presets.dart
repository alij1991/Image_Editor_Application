import '../pipeline/edit_op_type.dart';
import '../pipeline/edit_operation.dart';
import 'preset.dart';

/// Factory for the app's built-in presets.
///
/// Each preset is a curated list of [EditOperation]s that, when applied,
/// reproduce a recognizable photographic look. All use shader ops
/// already in the engine — no LUT assets required. (User-authored LUTs
/// can be added later via `EditOpType.lut3d` with an asset path.)
///
/// Canonical category strings used by the preset category rail:
///   'popular' · 'bw' · 'film' · 'portrait' · 'landscape' · 'bold'
class BuiltInPresets {
  BuiltInPresets._();

  static EditOperation _op(
    String type,
    Map<String, dynamic> params,
  ) =>
      EditOperation.create(type: type, parameters: params);

  static List<Preset> get all => [
        // --- Popular -----------------------------------------------------
        const Preset(
          id: 'builtin.none',
          name: 'Original',
          category: 'popular',
          builtIn: true,
          operations: [],
        ),
        Preset(
          id: 'builtin.natural',
          name: 'Natural',
          category: 'popular',
          builtIn: true,
          operations: [
            _op(EditOpType.exposure, {'value': 0.05}),
            _op(EditOpType.contrast, {'value': 0.08}),
            _op(EditOpType.highlights, {'value': -0.1}),
            _op(EditOpType.shadows, {'value': 0.1}),
            _op(EditOpType.vibrance, {'value': 0.1}),
          ],
        ),
        Preset(
          id: 'builtin.punch',
          name: 'Punch',
          category: 'popular',
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
          id: 'builtin.rich_hdr',
          name: 'Rich HDR',
          category: 'popular',
          builtIn: true,
          operations: [
            _op(EditOpType.shadows, {'value': 0.35}),
            _op(EditOpType.highlights, {'value': -0.35}),
            _op(EditOpType.whites, {'value': 0.15}),
            _op(EditOpType.blacks, {'value': 0.1}),
            _op(EditOpType.contrast, {'value': 0.12}),
            _op(EditOpType.clarity, {'value': 0.25}),
            _op(EditOpType.vibrance, {'value': 0.15}),
          ],
        ),
        Preset(
          id: 'builtin.fade',
          name: 'Fade',
          category: 'popular',
          builtIn: true,
          operations: [
            _op(EditOpType.contrast, {'value': -0.18}),
            _op(EditOpType.blacks, {'value': 0.22}),
            _op(EditOpType.shadows, {'value': 0.18}),
            _op(EditOpType.saturation, {'value': -0.05}),
          ],
        ),
        Preset(
          id: 'builtin.pastel',
          name: 'Pastel',
          category: 'popular',
          builtIn: true,
          operations: [
            _op(EditOpType.exposure, {'value': 0.1}),
            _op(EditOpType.contrast, {'value': -0.15}),
            _op(EditOpType.saturation, {'value': -0.15}),
            _op(EditOpType.temperature, {'value': 0.08}),
            _op(EditOpType.tint, {'value': 0.05}),
            _op(EditOpType.highlights, {'value': -0.15}),
            _op(EditOpType.shadows, {'value': 0.2}),
          ],
        ),

        // --- Portrait ----------------------------------------------------
        Preset(
          id: 'builtin.portrait_pop',
          name: 'Portrait Pop',
          category: 'portrait',
          builtIn: true,
          operations: [
            _op(EditOpType.exposure, {'value': 0.1}),
            _op(EditOpType.contrast, {'value': 0.1}),
            _op(EditOpType.highlights, {'value': -0.15}),
            _op(EditOpType.shadows, {'value': 0.2}),
            _op(EditOpType.vibrance, {'value': 0.25}),
            _op(EditOpType.clarity, {'value': 0.1}),
          ],
        ),
        Preset(
          id: 'builtin.warm_sun',
          name: 'Warm Sun',
          category: 'portrait',
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
          id: 'builtin.warm_sunset',
          name: 'Warm Sunset',
          category: 'portrait',
          builtIn: true,
          operations: [
            _op(EditOpType.temperature, {'value': 0.45}),
            _op(EditOpType.tint, {'value': 0.08}),
            _op(EditOpType.exposure, {'value': 0.15}),
            _op(EditOpType.contrast, {'value': 0.1}),
            _op(EditOpType.saturation, {'value': 0.1}),
            _op(EditOpType.highlights, {'value': -0.2}),
          ],
        ),

        // --- Landscape ---------------------------------------------------
        Preset(
          id: 'builtin.cinematic',
          name: 'Cinematic',
          category: 'landscape',
          builtIn: true,
          operations: [
            _op(EditOpType.contrast, {'value': 0.2}),
            _op(EditOpType.temperature, {'value': -0.08}),
            _op(EditOpType.tint, {'value': 0.06}),
            _op(EditOpType.shadows, {'value': -0.1}),
            _op(EditOpType.highlights, {'value': -0.2}),
            _op(EditOpType.clarity, {'value': 0.18}),
            _op(EditOpType.vignette, {
              'amount': 0.3,
              'feather': 0.4,
              'roundness': 0.5,
            }),
          ],
        ),
        Preset(
          id: 'builtin.teal_orange',
          name: 'Teal & Orange',
          category: 'landscape',
          builtIn: true,
          operations: [
            _op(EditOpType.temperature, {'value': 0.18}),
            _op(EditOpType.tint, {'value': -0.1}),
            _op(EditOpType.splitToning, {
              // Orange highlights, teal shadows — classic cinematic grade.
              'hiColor': [0.95, 0.65, 0.35],
              'loColor': [0.25, 0.55, 0.75],
              'balance': 0.0,
            }),
            _op(EditOpType.contrast, {'value': 0.15}),
            _op(EditOpType.vibrance, {'value': 0.2}),
            _op(EditOpType.saturation, {'value': 0.05}),
          ],
        ),
        Preset(
          id: 'builtin.moody',
          name: 'Moody',
          category: 'landscape',
          builtIn: true,
          operations: [
            _op(EditOpType.exposure, {'value': -0.1}),
            _op(EditOpType.contrast, {'value': 0.25}),
            _op(EditOpType.shadows, {'value': -0.2}),
            _op(EditOpType.highlights, {'value': -0.3}),
            _op(EditOpType.whites, {'value': -0.1}),
            _op(EditOpType.temperature, {'value': -0.1}),
            _op(EditOpType.saturation, {'value': -0.15}),
            _op(EditOpType.clarity, {'value': 0.2}),
          ],
        ),

        // --- Film --------------------------------------------------------
        Preset(
          id: 'builtin.film_portra',
          name: 'Film · Portra',
          category: 'film',
          builtIn: true,
          operations: [
            _op(EditOpType.temperature, {'value': 0.12}),
            _op(EditOpType.tint, {'value': 0.05}),
            _op(EditOpType.saturation, {'value': -0.1}),
            _op(EditOpType.vibrance, {'value': 0.08}),
            _op(EditOpType.highlights, {'value': -0.15}),
            _op(EditOpType.shadows, {'value': 0.12}),
            _op(EditOpType.contrast, {'value': -0.05}),
            _op(EditOpType.grain, {'amount': 0.12, 'cellSize': 2.0}),
          ],
        ),
        Preset(
          id: 'builtin.film_kodachrome',
          name: 'Film · Kodachrome',
          category: 'film',
          builtIn: true,
          operations: [
            _op(EditOpType.temperature, {'value': 0.08}),
            _op(EditOpType.saturation, {'value': 0.15}),
            _op(EditOpType.vibrance, {'value': 0.1}),
            _op(EditOpType.contrast, {'value': 0.15}),
            _op(EditOpType.highlights, {'value': -0.1}),
            _op(EditOpType.shadows, {'value': -0.05}),
            _op(EditOpType.grain, {'amount': 0.15, 'cellSize': 2.0}),
          ],
        ),
        Preset(
          id: 'builtin.vintage',
          name: 'Vintage',
          category: 'film',
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
          category: 'film',
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
          id: 'builtin.matte',
          name: 'Matte',
          category: 'film',
          builtIn: true,
          operations: [
            _op(EditOpType.contrast, {'value': -0.22}),
            _op(EditOpType.shadows, {'value': 0.35}),
            _op(EditOpType.blacks, {'value': 0.18}),
            _op(EditOpType.saturation, {'value': -0.1}),
            _op(EditOpType.temperature, {'value': 0.05}),
            _op(EditOpType.highlights, {'value': -0.1}),
          ],
        ),
        Preset(
          id: 'builtin.sepia',
          name: 'Sepia',
          category: 'film',
          builtIn: true,
          operations: [
            _op(EditOpType.saturation, {'value': -1.0}),
            _op(EditOpType.temperature, {'value': 0.35}),
            _op(EditOpType.tint, {'value': 0.15}),
            _op(EditOpType.contrast, {'value': 0.12}),
            _op(EditOpType.highlights, {'value': -0.1}),
          ],
        ),

        // --- Bold --------------------------------------------------------
        Preset(
          id: 'builtin.dramatic',
          name: 'Dramatic',
          category: 'bold',
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
          id: 'builtin.cyberpunk',
          name: 'Cyberpunk',
          category: 'bold',
          builtIn: true,
          operations: [
            _op(EditOpType.temperature, {'value': -0.2}),
            _op(EditOpType.tint, {'value': 0.25}),
            _op(EditOpType.saturation, {'value': 0.35}),
            _op(EditOpType.contrast, {'value': 0.3}),
            _op(EditOpType.shadows, {'value': -0.15}),
            _op(EditOpType.clarity, {'value': 0.2}),
          ],
        ),

        // --- B&W ---------------------------------------------------------
        Preset(
          id: 'builtin.mono',
          name: 'Mono',
          category: 'bw',
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
          id: 'builtin.noir',
          name: 'Noir',
          category: 'bw',
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
        Preset(
          id: 'builtin.sharp_bw',
          name: 'Sharp B&W',
          category: 'bw',
          builtIn: true,
          operations: [
            _op(EditOpType.saturation, {'value': -1.0}),
            _op(EditOpType.contrast, {'value': 0.4}),
            _op(EditOpType.clarity, {'value': 0.35}),
            _op(EditOpType.sharpen, {'amount': 0.3, 'radius': 1.2}),
            _op(EditOpType.whites, {'value': 0.15}),
            _op(EditOpType.blacks, {'value': -0.2}),
          ],
        ),
        Preset(
          id: 'builtin.bw_gold',
          name: 'B&W Gold',
          category: 'bw',
          builtIn: true,
          operations: [
            _op(EditOpType.saturation, {'value': -1.0}),
            _op(EditOpType.contrast, {'value': 0.25}),
            _op(EditOpType.temperature, {'value': 0.3}),
            _op(EditOpType.shadows, {'value': 0.1}),
            _op(EditOpType.highlights, {'value': -0.1}),
            _op(EditOpType.grain, {'amount': 0.15, 'cellSize': 2.0}),
          ],
        ),
        Preset(
          id: 'builtin.silver',
          name: 'Silver',
          category: 'bw',
          builtIn: true,
          operations: [
            _op(EditOpType.saturation, {'value': -1.0}),
            _op(EditOpType.contrast, {'value': -0.1}),
            _op(EditOpType.shadows, {'value': 0.25}),
            _op(EditOpType.blacks, {'value': 0.18}),
            _op(EditOpType.whites, {'value': -0.1}),
            _op(EditOpType.temperature, {'value': -0.1}),
          ],
        ),
      ];

  /// Canonical category identifiers used by the preset category rail.
  static const List<String> categories = [
    'popular',
    'portrait',
    'landscape',
    'film',
    'bw',
    'bold',
  ];

  /// Display label for a category identifier.
  static String labelFor(String category) => switch (category) {
        'popular' => 'Popular',
        'portrait' => 'Portrait',
        'landscape' => 'Landscape',
        'film' => 'Film',
        'bw' => 'B&W',
        'bold' => 'Bold',
        _ => category,
      };
}
