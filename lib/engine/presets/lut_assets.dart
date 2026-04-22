/// Phase X.A.4 — typed asset-path constants for the bundled 3D LUTs.
///
/// Before X.A.4, each `Preset` hand-wrote the LUT path as a raw
/// string (`'assets/luts/cool_33.png'`). A typo meant a silent
/// "LUT not found" at runtime; changing a LUT id meant grep + manual
/// sweep through every preset. This file is the single source of
/// truth — `tool/bake_luts.dart` produces the `<id>.png` files, and
/// this class exposes them as `static const` strings so the
/// Dart compiler catches rename drift.
///
/// **How to add a new LUT**:
///   1. Add a `Lut(id: 'foo_33', …)` entry to `tool/bake_luts.dart`'s
///      `_bakeList`.
///   2. Run `dart run tool/bake_luts.dart` — writes
///      `assets/luts/foo_33.png` + updates the manifest.
///   3. Add `static const foo = '$kLutRoot/foo_33.png';` below.
///   4. Reference `LutAssets.foo` from any preset that uses it.
class LutAssets {
  LutAssets._();

  /// Root directory for bundled LUTs. Matches `kAssetsDir` in
  /// `tool/bake_luts.dart`.
  static const String root = 'assets/luts';

  /// Debug identity — neutral RGB passthrough. Shouldn't appear in
  /// user-facing presets.
  static const String identity = '$root/identity_33.png';

  /// Luminance-preserving monochrome (Rec.709 luma weights).
  static const String mono = '$root/mono_33.png';

  /// Sepia — warm split-tone on the luminance.
  static const String sepia = '$root/sepia_33.png';

  /// Subtle cool cast — shadows blue, highlights cyan.
  static const String cool = '$root/cool_33.png';

  /// Subtle warm cast — shadows amber, highlights warm white.
  static const String warm = '$root/warm_33.png';

  /// Every registered LUT asset path. Used by tests + future Model
  /// Manager-style pre-flight validators to confirm every declared
  /// LUT actually exists under `assets/luts/`.
  static const List<String> all = <String>[
    identity,
    mono,
    sepia,
    cool,
    warm,
  ];
}
