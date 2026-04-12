import 'package:flutter_test/flutter_test.dart';

import 'package:image_editor/engine/color/curve.dart';

void main() {
  group('ToneCurve', () {
    test('identity passes through', () {
      final c = ToneCurve.identity();
      for (final x in [0.0, 0.1, 0.25, 0.5, 0.75, 1.0]) {
        expect(c.evaluate(x), closeTo(x, 1e-6));
      }
    });

    test('evaluates clamped outside range', () {
      final c = ToneCurve.identity();
      expect(c.evaluate(-0.5), 0);
      expect(c.evaluate(1.5), 1);
    });

    test('S-curve pushes midtones outward', () {
      final c = ToneCurve.sCurve(0.15);
      // Endpoints preserved.
      expect(c.evaluate(0), closeTo(0, 1e-6));
      expect(c.evaluate(1), closeTo(1, 1e-6));
      // Shadow quarter is darker, highlight quarter is brighter.
      expect(c.evaluate(0.25), lessThan(0.25));
      expect(c.evaluate(0.75), greaterThan(0.75));
    });

    test('monotonic interpolation never overshoots control points', () {
      final c = ToneCurve([
        const CurvePoint(0, 0),
        const CurvePoint(0.5, 1),
        const CurvePoint(1, 1),
      ]);
      for (double x = 0; x <= 1; x += 0.01) {
        final y = c.evaluate(x);
        expect(y, inInclusiveRange(0, 1));
      }
    });

    test('ctor throws if fewer than two points', () {
      expect(
        () => ToneCurve([const CurvePoint(0, 0)]),
        throwsArgumentError,
      );
    });
  });
}
