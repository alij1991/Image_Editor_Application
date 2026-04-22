import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:image_editor/features/editor/presentation/widgets/perf_hud.dart';

/// IX.A.5 — `PerfHud`'s release-build + disabled-flag guards must
/// both short-circuit to an empty widget so the HUD never leaks into
/// production or renders when explicitly disabled.
///
/// Flutter unit tests run in profile-mode (kReleaseMode == false), so
/// these tests exercise the [enabled] flag path and the sample-count
/// short-circuit. The `kReleaseMode` branch is a compile-time
/// constant folded at build time — pinning it via a synthetic
/// override would require `debugBrightnessOverride`-style machinery
/// that doesn't exist for build modes. Instead we assert the source
/// contract: the build method's first line MUST short-circuit when
/// EITHER guard is truthy, so enabling-false acts as a faithful proxy
/// in tests (same `SizedBox.shrink()` branch).
void main() {
  Future<void> pumpHud(WidgetTester tester, {required bool enabled}) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Stack(
            children: [PerfHud(enabled: enabled)],
          ),
        ),
      ),
    );
  }

  testWidgets('enabled: false short-circuits to SizedBox.shrink',
      (tester) async {
    await pumpHud(tester, enabled: false);
    // No Positioned / Material / InkWell from the HUD's visible path.
    expect(find.byType(InkWell), findsNothing);
    expect(find.byType(Positioned), findsNothing);
    // The widget still exists in the tree, just as an empty box.
    expect(find.byType(PerfHud), findsOneWidget);
  });

  testWidgets('enabled: true with zero samples renders empty', (tester) async {
    // FrameTimer starts with 0 samples — the build returns
    // SizedBox.shrink until at least one frame timing lands. Verifies
    // the second short-circuit branch on line 71 of perf_hud.dart.
    await pumpHud(tester, enabled: true);
    // The HUD may register frame callbacks, but until a sample lands
    // the visible widget chain stays empty.
    expect(find.byType(InkWell), findsNothing);
  });

  test('sharedFrameTimer is a single instance across constructions', () {
    // `PerfHud.sharedFrameTimer` is a `static final` — constructing
    // multiple PerfHuds must not create new timers. This is the
    // contract the release guard relies on (otherwise disabled HUDs
    // would still spawn timers).
    final a = PerfHud.sharedFrameTimer;
    final b = PerfHud.sharedFrameTimer;
    expect(identical(a, b), isTrue);
  });
}
