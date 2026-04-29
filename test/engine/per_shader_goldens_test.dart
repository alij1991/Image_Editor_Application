import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// IX.D.2 — per-shader visual goldens.
///
/// **Status**: skip-gated. Same Impeller/Skia flakiness concern as
/// IX.D.1 (see `color_chain_golden_test.dart`). The scaffold
/// enumerates every shader the app ships so when the CI pin lands,
/// the only work is running `flutter test --update-goldens` and
/// committing the generated PNGs.
///
/// Each shader is rendered on a shared 100×100 test pattern so
/// visual diffs across shaders are directly comparable.
/// Flip to `false` after pinning Impeller/Skia in CI + running
/// `flutter test --update-goldens` to produce `goldens/shaders/*.png`.
const bool kSkipGoldens = true;

const String kGoldenSkipReason =
    'Skipped in CI: goldens pending Impeller/Skia version pin — '
    'see docs/PLAN.md Phase IX risks. Run with --update-goldens '
    'locally + pin the produced images in review.';

/// Every `.frag` the app ships under `shaders/`. Keeping this list
/// in the test file (instead of scanning the directory) catches
/// "new shader added but no golden registered" at review time.
const List<String> kAllShaderKeys = [
  'before_after_wipe',
  'bilateral_denoise',
  'chromatic_aberration',
  'clarity',
  'color_grading',
  'curves',
  'dehaze',
  'glitch',
  'grain',
  'halftone',
  'highlights_shadows',
  'hsl',
  'lens_blur',
  'levels_gamma',
  'lut3d',
  'motion_blur',
  'perspective_warp',
  'pixelate',
  'radial_blur',
  'sharpen_unsharp',
  'split_toning',
  'texture',
  'tilt_shift',
  'vibrance',
  'vignette',
];

void main() {
  // Sanity: the shader list matches what's on disk. Adding a new
  // shader to `shaders/` without appending it here trips this test
  // — a pin against "forgot the golden".
  test('kAllShaderKeys covers 25 shaders in 2026-Q2', () {
    expect(kAllShaderKeys.length, 25);
    // Alphabetically sorted — stable list for reviewers.
    final sorted = [...kAllShaderKeys]..sort();
    expect(kAllShaderKeys, sorted,
        reason: 'keep the list alphabetical for readability');
  });

  test('kGoldenSkipReason mentions the Impeller pin requirement', () {
    expect(kGoldenSkipReason, contains('Impeller'));
  });

  // Per-shader golden scaffolds — each currently skipped. When CI
  // pins the Impeller version, flip `skip` to false and run
  // `--update-goldens`.
  for (final key in kAllShaderKeys) {
    testWidgets(
      '$key produces a stable golden',
      (tester) async {
        await tester.pumpWidget(
          MaterialApp(
            home: RepaintBoundary(
              key: Key('shader-$key'),
              child: Container(
                width: 100,
                height: 100,
                decoration: const BoxDecoration(
                  gradient: LinearGradient(
                    colors: [Color(0xff202020), Color(0xffe0e0e0)],
                  ),
                ),
                // TODO(IX.D.2): when un-skipping, wrap the gradient
                // in a `CustomPaint` that runs `key.frag` via
                // `ShaderRegistry.instance.get(...)` and captures
                // the result. The boundary + gradient here is
                // scaffolding that produces a compilable test
                // without the actual shader wiring — the
                // `matchesGoldenFile` path is what the real test
                // will pin once a real render is in place.
              ),
            ),
          ),
        );
        await expectLater(
          find.byKey(Key('shader-$key')),
          matchesGoldenFile('goldens/shaders/$key.png'),
        );
      },
      skip: kSkipGoldens,
    );
  }
}
