import 'package:flutter_test/flutter_test.dart';

import 'package:image_editor/features/scanner/data/image_processor.dart';
import 'package:image_editor/features/scanner/domain/models/scan_models.dart';

/// VIII.20 — tightened `_isFullRect` tolerance from 0.01 to 0.005 so
/// near-identity drags short-circuit the perspective warp.
void main() {
  Corners at(double inset) => Corners(
        Point2(inset, inset),
        Point2(1 - inset, inset),
        Point2(1 - inset, 1 - inset),
        Point2(inset, 1 - inset),
      );

  test('tolerance constant equals 0.005', () {
    expect(kFullRectTolerance, 0.005);
  });

  test('corners at (0, 0) are near-identity', () {
    expect(isNearIdentityRect(at(0)), isTrue);
  });

  test('corners at inset 0.005 are still near-identity (inclusive)', () {
    expect(isNearIdentityRect(at(0.005)), isTrue);
  });

  test('corners at inset 0.006 trigger a warp (just past threshold)', () {
    expect(isNearIdentityRect(at(0.006)), isFalse);
  });

  test('corners at inset 0.01 (the old tolerance) trigger a warp', () {
    expect(isNearIdentityRect(at(0.01)), isFalse);
  });

  test('Corners.inset() (0.05 default) is not near-identity', () {
    expect(isNearIdentityRect(Corners.inset()), isFalse);
  });

  test('asymmetric drag on a single corner triggers a warp', () {
    const c = Corners(
      Point2(0.02, 0),
      Point2(1, 0),
      Point2(1, 1),
      Point2(0, 1),
    );
    expect(isNearIdentityRect(c), isFalse);
  });
}
