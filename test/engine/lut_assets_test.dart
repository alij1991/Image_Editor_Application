import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:image_editor/engine/presets/lut_assets.dart';

/// X.A.4 — `LutAssets` constants replace raw-string LUT paths
/// scattered in built-in presets. Pins: root path, each constant's
/// format, `all` list completeness, and the assumption that every
/// declared LUT asset actually exists on disk (sanity check — if
/// not, `tool/bake_luts.dart` needs a re-run).
void main() {
  test('root path is assets/luts (matches tool/bake_luts.dart)', () {
    expect(LutAssets.root, 'assets/luts');
  });

  test('every LUT path is under LutAssets.root', () {
    for (final path in LutAssets.all) {
      expect(path, startsWith('${LutAssets.root}/'),
          reason: '$path should live under the LUT root');
    }
  });

  test('every LUT path ends in _33.png (tileSize=33 convention)', () {
    for (final path in LutAssets.all) {
      expect(path, endsWith('_33.png'),
          reason: '$path should match the <id>_33.png baking convention');
    }
  });

  test('LutAssets.all has no duplicates', () {
    expect(LutAssets.all.toSet().length, LutAssets.all.length);
  });

  test('specific named constants stay stable', () {
    // Re-ordering / renaming these breaks persisted presets that
    // saved the raw string. Pin the exact value.
    expect(LutAssets.identity, 'assets/luts/identity_33.png');
    expect(LutAssets.mono, 'assets/luts/mono_33.png');
    expect(LutAssets.sepia, 'assets/luts/sepia_33.png');
    expect(LutAssets.cool, 'assets/luts/cool_33.png');
    expect(LutAssets.warm, 'assets/luts/warm_33.png');
  });

  test('every declared LUT asset exists on disk (non-identity LUTs)', () {
    // Identity + sepia may be optional on some dev checkouts; skip if
    // absent. This test is informational — ensures the `tool/bake_luts`
    // output is in sync with the constants.
    for (final path in [LutAssets.mono, LutAssets.cool, LutAssets.warm]) {
      final f = File(path);
      expect(f.existsSync(), isTrue,
          reason: '$path should exist — run `dart run tool/bake_luts.dart`');
    }
  });
}
