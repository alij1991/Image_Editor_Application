import '../pipeline/edit_op_type.dart';
import '../pipeline/edit_operation.dart';
import 'preset.dart';

/// Factory for the app's built-in presets.
///
/// Each preset is a curated list of [EditOperation]s that, when applied,
/// reproduce a recognizable photographic look. All use shader ops
/// already in the engine — no LUT assets required.
///
/// Design principles (post-2026 rebalance):
///   - Values stay inside "safe" ceilings documented by Adobe / VSCO
///     practitioners so a preset never degrades a well-shot photo at
///     100% intensity.
///   - Clarity on skin (portraits) is avoided — it's the #1 thing every
///     portrait-preset guide warns against.
///   - Shadow/highlight symmetry is capped at ±0.25 — higher values
///     produce the HDR-crunchy "every detail visible, no depth" look.
///   - Presets that deliberately push past safe ceilings (Noir,
///     Dramatic, Cyberpunk, Moody, Sharp B&W, Sepia) are tagged
///     [PresetStrength.strong] in `preset_metadata.dart` so the UI
///     surfaces a badge + a lower default intensity (80%).
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
            _op(EditOpType.highlights, {'value': -0.10}),
            _op(EditOpType.shadows, {'value': 0.10}),
            _op(EditOpType.vibrance, {'value': 0.10}),
          ],
        ),
        Preset(
          id: 'builtin.punch',
          name: 'Punch',
          category: 'popular',
          builtIn: true,
          operations: [
            _op(EditOpType.contrast, {'value': 0.18}),
            _op(EditOpType.saturation, {'value': 0.10}),
            _op(EditOpType.vibrance, {'value': 0.18}),
            _op(EditOpType.shadows, {'value': 0.12}),
            _op(EditOpType.highlights, {'value': -0.15}),
          ],
        ),
        Preset(
          id: 'builtin.rich_hdr',
          name: 'Rich HDR',
          category: 'popular',
          builtIn: true,
          operations: [
            // Rebalanced: symmetric shadow/highlight push dropped from
            // ±0.35 → ±0.22/-0.25 and clarity 0.25 → 0.12 so the HDR
            // character stays without the crunchy-detail look.
            _op(EditOpType.shadows, {'value': 0.22}),
            _op(EditOpType.highlights, {'value': -0.25}),
            _op(EditOpType.whites, {'value': 0.10}),
            _op(EditOpType.blacks, {'value': 0.08}),
            _op(EditOpType.contrast, {'value': 0.15}),
            _op(EditOpType.clarity, {'value': 0.12}),
            _op(EditOpType.vibrance, {'value': 0.12}),
          ],
        ),
        Preset(
          id: 'builtin.fade',
          name: 'Fade',
          category: 'popular',
          builtIn: true,
          operations: [
            _op(EditOpType.contrast, {'value': -0.15}),
            _op(EditOpType.blacks, {'value': 0.15}),
            _op(EditOpType.shadows, {'value': 0.15}),
            _op(EditOpType.saturation, {'value': -0.05}),
          ],
        ),
        Preset(
          id: 'builtin.pastel',
          name: 'Pastel',
          category: 'popular',
          builtIn: true,
          operations: [
            _op(EditOpType.exposure, {'value': 0.08}),
            _op(EditOpType.contrast, {'value': -0.12}),
            _op(EditOpType.saturation, {'value': -0.10}),
            _op(EditOpType.temperature, {'value': 0.06}),
            _op(EditOpType.tint, {'value': 0.04}),
            _op(EditOpType.highlights, {'value': -0.12}),
            _op(EditOpType.shadows, {'value': 0.15}),
          ],
        ),

        // --- Portrait ----------------------------------------------------
        Preset(
          id: 'builtin.portrait_pop',
          name: 'Portrait Pop',
          category: 'portrait',
          builtIn: true,
          operations: [
            // Rebalanced: removed clarity (hero-killer on skin), bumped
            // highlights recovery slightly to protect skin tones.
            _op(EditOpType.exposure, {'value': 0.08}),
            _op(EditOpType.contrast, {'value': 0.08}),
            _op(EditOpType.highlights, {'value': -0.18}),
            _op(EditOpType.shadows, {'value': 0.15}),
            _op(EditOpType.vibrance, {'value': 0.18}),
            _op(EditOpType.saturation, {'value': -0.03}),
          ],
        ),
        Preset(
          id: 'builtin.warm_sun',
          name: 'Warm Sun',
          category: 'portrait',
          builtIn: true,
          operations: [
            _op(EditOpType.temperature, {'value': 0.22}),
            _op(EditOpType.exposure, {'value': 0.15}),
            _op(EditOpType.vibrance, {'value': 0.18}),
            _op(EditOpType.highlights, {'value': -0.10}),
            _op(EditOpType.shadows, {'value': 0.12}),
          ],
        ),
        Preset(
          id: 'builtin.warm_sunset',
          name: 'Warm Sunset',
          category: 'portrait',
          builtIn: true,
          operations: [
            _op(EditOpType.temperature, {'value': 0.28}),
            _op(EditOpType.tint, {'value': 0.06}),
            _op(EditOpType.exposure, {'value': 0.10}),
            _op(EditOpType.contrast, {'value': 0.08}),
            _op(EditOpType.saturation, {'value': 0.06}),
            _op(EditOpType.highlights, {'value': -0.18}),
          ],
        ),

        // --- Landscape ---------------------------------------------------
        Preset(
          id: 'builtin.cinematic',
          name: 'Cinematic',
          category: 'landscape',
          builtIn: true,
          operations: [
            _op(EditOpType.contrast, {'value': 0.18}),
            _op(EditOpType.temperature, {'value': -0.08}),
            _op(EditOpType.tint, {'value': 0.05}),
            _op(EditOpType.shadows, {'value': -0.08}),
            _op(EditOpType.highlights, {'value': -0.18}),
            _op(EditOpType.clarity, {'value': 0.12}),
            _op(EditOpType.vignette, {
              'amount': 0.28,
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
            _op(EditOpType.temperature, {'value': 0.15}),
            _op(EditOpType.tint, {'value': -0.08}),
            _op(EditOpType.splitToning, {
              // Orange highlights, teal shadows — classic cinematic grade.
              'hiColor': [0.95, 0.65, 0.35],
              'loColor': [0.25, 0.55, 0.75],
              'balance': 0.0,
            }),
            _op(EditOpType.contrast, {'value': 0.12}),
            _op(EditOpType.vibrance, {'value': 0.15}),
            _op(EditOpType.saturation, {'value': 0.05}),
          ],
        ),
        Preset(
          id: 'builtin.moody',
          name: 'Moody',
          category: 'landscape',
          builtIn: true,
          operations: [
            _op(EditOpType.exposure, {'value': -0.08}),
            _op(EditOpType.contrast, {'value': 0.22}),
            _op(EditOpType.shadows, {'value': -0.15}),
            _op(EditOpType.highlights, {'value': -0.25}),
            _op(EditOpType.whites, {'value': -0.08}),
            _op(EditOpType.temperature, {'value': -0.08}),
            _op(EditOpType.saturation, {'value': -0.12}),
            _op(EditOpType.clarity, {'value': 0.15}),
          ],
        ),

        // --- Film --------------------------------------------------------
        Preset(
          id: 'builtin.film_portra',
          name: 'Film · Portra',
          category: 'film',
          builtIn: true,
          operations: [
            _op(EditOpType.temperature, {'value': 0.10}),
            _op(EditOpType.tint, {'value': 0.04}),
            _op(EditOpType.saturation, {'value': -0.08}),
            _op(EditOpType.vibrance, {'value': 0.08}),
            _op(EditOpType.highlights, {'value': -0.12}),
            _op(EditOpType.shadows, {'value': 0.10}),
            _op(EditOpType.contrast, {'value': -0.04}),
            _op(EditOpType.grain, {'amount': 0.10, 'cellSize': 2.0}),
          ],
        ),
        Preset(
          id: 'builtin.film_kodachrome',
          name: 'Film · Kodachrome',
          category: 'film',
          builtIn: true,
          operations: [
            _op(EditOpType.temperature, {'value': 0.08}),
            _op(EditOpType.saturation, {'value': 0.08}),
            _op(EditOpType.vibrance, {'value': 0.10}),
            _op(EditOpType.contrast, {'value': 0.12}),
            _op(EditOpType.highlights, {'value': -0.10}),
            _op(EditOpType.shadows, {'value': -0.05}),
            _op(EditOpType.grain, {'amount': 0.12, 'cellSize': 2.0}),
          ],
        ),
        Preset(
          id: 'builtin.vintage',
          name: 'Vintage',
          category: 'film',
          builtIn: true,
          operations: [
            _op(EditOpType.temperature, {'value': 0.18}),
            _op(EditOpType.tint, {'value': -0.08}),
            _op(EditOpType.saturation, {'value': -0.18}),
            _op(EditOpType.contrast, {'value': -0.08}),
            _op(EditOpType.shadows, {'value': 0.15}),
            _op(EditOpType.highlights, {'value': -0.20}),
            _op(EditOpType.grain, {'amount': 0.15, 'cellSize': 2.0}),
            _op(EditOpType.vignette, {
              'amount': 0.30,
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
            _op(EditOpType.temperature, {'value': -0.18}),
            _op(EditOpType.tint, {'value': 0.06}),
            _op(EditOpType.saturation, {'value': -0.12}),
            _op(EditOpType.contrast, {'value': 0.08}),
            _op(EditOpType.highlights, {'value': -0.12}),
          ],
        ),
        Preset(
          id: 'builtin.matte',
          name: 'Matte',
          category: 'film',
          builtIn: true,
          operations: [
            _op(EditOpType.contrast, {'value': -0.18}),
            _op(EditOpType.shadows, {'value': 0.25}),
            _op(EditOpType.blacks, {'value': 0.15}),
            _op(EditOpType.saturation, {'value': -0.08}),
            _op(EditOpType.temperature, {'value': 0.05}),
            _op(EditOpType.highlights, {'value': -0.10}),
          ],
        ),
        Preset(
          id: 'builtin.sepia',
          name: 'Sepia',
          category: 'film',
          builtIn: true,
          operations: [
            _op(EditOpType.saturation, {'value': -1.0}),
            _op(EditOpType.temperature, {'value': 0.30}),
            _op(EditOpType.tint, {'value': 0.12}),
            _op(EditOpType.contrast, {'value': 0.10}),
            _op(EditOpType.highlights, {'value': -0.10}),
          ],
        ),

        // --- Bold --------------------------------------------------------
        // "Strong" presets — intentionally stylised; tagged in
        // preset_metadata.dart so the UI shows a badge.
        Preset(
          id: 'builtin.dramatic',
          name: 'Dramatic',
          category: 'bold',
          builtIn: true,
          operations: [
            _op(EditOpType.contrast, {'value': 0.30}),
            _op(EditOpType.clarity, {'value': 0.22}),
            _op(EditOpType.vibrance, {'value': 0.22}),
            _op(EditOpType.shadows, {'value': -0.12}),
            _op(EditOpType.whites, {'value': 0.18}),
            _op(EditOpType.blacks, {'value': -0.18}),
            _op(EditOpType.vignette, {
              'amount': 0.45,
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
            _op(EditOpType.temperature, {'value': -0.18}),
            _op(EditOpType.tint, {'value': 0.18}),
            _op(EditOpType.saturation, {'value': 0.25}),
            _op(EditOpType.contrast, {'value': 0.22}),
            _op(EditOpType.shadows, {'value': -0.12}),
            _op(EditOpType.clarity, {'value': 0.15}),
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
            _op(EditOpType.contrast, {'value': 0.20}),
            _op(EditOpType.vignette, {
              'amount': 0.28,
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
            _op(EditOpType.contrast, {'value': 0.35}),
            _op(EditOpType.whites, {'value': 0.22}),
            _op(EditOpType.blacks, {'value': -0.28}),
            _op(EditOpType.vignette, {
              'amount': 0.45,
              'feather': 0.3,
              'roundness': 0.5,
            }),
            _op(EditOpType.grain, {'amount': 0.22, 'cellSize': 2.0}),
          ],
        ),
        Preset(
          id: 'builtin.sharp_bw',
          name: 'Sharp B&W',
          category: 'bw',
          builtIn: true,
          operations: [
            _op(EditOpType.saturation, {'value': -1.0}),
            _op(EditOpType.contrast, {'value': 0.30}),
            _op(EditOpType.clarity, {'value': 0.25}),
            _op(EditOpType.sharpen, {'amount': 0.25, 'radius': 1.2}),
            _op(EditOpType.whites, {'value': 0.12}),
            _op(EditOpType.blacks, {'value': -0.18}),
          ],
        ),
        Preset(
          id: 'builtin.bw_gold',
          name: 'B&W Gold',
          category: 'bw',
          builtIn: true,
          operations: [
            _op(EditOpType.saturation, {'value': -1.0}),
            _op(EditOpType.contrast, {'value': 0.20}),
            _op(EditOpType.temperature, {'value': 0.22}),
            _op(EditOpType.shadows, {'value': 0.10}),
            _op(EditOpType.highlights, {'value': -0.10}),
            _op(EditOpType.grain, {'amount': 0.12, 'cellSize': 2.0}),
          ],
        ),
        Preset(
          id: 'builtin.silver',
          name: 'Silver',
          category: 'bw',
          builtIn: true,
          operations: [
            _op(EditOpType.saturation, {'value': -1.0}),
            _op(EditOpType.contrast, {'value': -0.08}),
            _op(EditOpType.shadows, {'value': 0.20}),
            _op(EditOpType.blacks, {'value': 0.15}),
            _op(EditOpType.whites, {'value': -0.08}),
            _op(EditOpType.temperature, {'value': -0.08}),
          ],
        ),

        // --- LUT-backed (uses bundled .png LUTs from tool/bake_luts.dart) ---
        // These presets demonstrate the lut3d pipeline path. Add more by
        // (1) adding a Lut entry to tool/bake_luts.dart, (2) re-running
        // `dart run tool/bake_luts.dart`, (3) referencing the assetPath
        // here. Stack other ops on top for finishing touches.
        Preset(
          id: 'builtin.lut_cool_film',
          name: 'Cool Film (LUT)',
          category: 'film',
          builtIn: true,
          operations: [
            _op(EditOpType.lut3d, {
              'assetPath': 'assets/luts/cool_33.png',
              'intensity': 0.85,
            }),
            _op(EditOpType.contrast, {'value': 0.1}),
            _op(EditOpType.grain, {'amount': 0.18, 'cellSize': 2.0}),
          ],
        ),
        Preset(
          id: 'builtin.lut_sun_warm',
          name: 'Sun Warm (LUT)',
          category: 'film',
          builtIn: true,
          operations: [
            _op(EditOpType.lut3d, {
              'assetPath': 'assets/luts/warm_33.png',
              'intensity': 0.85,
            }),
            _op(EditOpType.vibrance, {'value': 0.15}),
            _op(EditOpType.shadows, {'value': 0.08}),
          ],
        ),
        Preset(
          id: 'builtin.lut_mono',
          name: 'Mono (LUT)',
          category: 'bw',
          builtIn: true,
          operations: [
            _op(EditOpType.lut3d, {
              'assetPath': 'assets/luts/mono_33.png',
              'intensity': 1.0,
            }),
            _op(EditOpType.contrast, {'value': 0.18}),
            _op(EditOpType.grain, {'amount': 0.12, 'cellSize': 2.0}),
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
