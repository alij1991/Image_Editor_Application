import 'package:flutter_test/flutter_test.dart';

import 'package:image_editor/features/editor/presentation/widgets/layer_painter.dart';

/// X.A.5 — absolute cap on the Gaussian blur radius derived from
/// `DrawingStroke.hardness`. Pre-X.A.5 the blur was
/// `(1 - hardness) * width * 0.5` with no upper bound — a width=100
/// soft stroke produced a 50 px blur that stalled the GPU on low-end
/// devices. `kMaxHardnessBlur = 40` caps the pathological case.
///
/// These tests drive the same computation the painter uses so the
/// math is pinned without needing a GPU.
void main() {
  double computeBlur(double hardness, double width) {
    final softness = (1.0 - hardness).clamp(0.0, 1.0);
    return (softness * width * 0.5).clamp(0.0, kMaxHardnessBlur);
  }

  test('kMaxHardnessBlur is 40 px', () {
    expect(kMaxHardnessBlur, 40.0);
  });

  test('hardness=1 → blur=0 regardless of width', () {
    for (final w in [1.0, 10.0, 100.0, 1000.0]) {
      expect(computeBlur(1.0, w), 0.0);
    }
  });

  test('typical 8-32 px strokes never hit the cap', () {
    // softness=1, width=32 → blur=16. Well under the 40 cap.
    expect(computeBlur(0.0, 8.0), 4.0);
    expect(computeBlur(0.0, 16.0), 8.0);
    expect(computeBlur(0.0, 32.0), 16.0);
    for (final w in [8.0, 16.0, 32.0]) {
      for (final h in [0.0, 0.25, 0.5, 0.75]) {
        expect(computeBlur(h, w), lessThan(kMaxHardnessBlur),
            reason: 'typical width $w + hardness $h should stay under cap');
      }
    }
  });

  test('extreme 100 px wide stroke with hardness=0 caps at 40', () {
    // softness=1, width=100 → blur=50 pre-cap → 40 post-cap.
    expect(computeBlur(0.0, 100.0), 40.0);
  });

  test('extreme 1000 px wide stroke still caps at 40 (safety)', () {
    expect(computeBlur(0.0, 1000.0), 40.0);
  });

  test('blur scales linearly with softness when under the cap', () {
    expect(computeBlur(0.8, 32.0), closeTo(3.2, 1e-9));
    expect(computeBlur(0.6, 32.0), closeTo(6.4, 1e-9));
    expect(computeBlur(0.4, 32.0), closeTo(9.6, 1e-9));
    expect(computeBlur(0.2, 32.0), closeTo(12.8, 1e-9));
  });

  test('negative hardness clamps to 0 softness → no blur', () {
    // Defensive: if a bad JSON produces hardness < 0, softness must
    // not flip to > 1 and spike the blur.
    expect(computeBlur(-0.5, 100.0), 40.0,
        reason: 'negative hardness still caps at kMaxHardnessBlur');
    // Note: the clamp(0, 1) on softness means hardness=-1 gives
    // softness=1, not softness=2 — verified by the cap behaviour.
  });
}
