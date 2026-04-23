import 'package:flutter_test/flutter_test.dart';

import 'package:image_editor/features/scanner/infrastructure/hough_quad_corner_seed.dart';

/// Phase XVI.3: unit coverage for the pure-Dart quad-fit pipeline
/// inside [HoughQuadCornerSeed]. Exercises the step that turns
/// Hough line segments into a validated 4-corner quad, without
/// needing a real OpenCV Canny chain.
void main() {
  group('HoughQuadCornerSeed.pickQuad', () {
    test('returns null when fewer than 4 segments are provided', () {
      final result = HoughQuadCornerSeed.pickQuad(
        segments: const [
          (0, 0, 100, 0),
          (0, 0, 0, 100),
        ],
        frameWidth: 200,
        frameHeight: 200,
      );
      expect(result, isNull);
    });

    test('picks the axis-aligned page bounds from 4 long edges', () {
      // Four long axis-aligned edges laying out a 160×120 page
      // inside a 200×200 frame, centred.
      final result = HoughQuadCornerSeed.pickQuad(
        segments: const [
          (20, 40, 180, 40),    // top
          (20, 160, 180, 160),  // bottom
          (20, 40, 20, 160),    // left
          (180, 40, 180, 160),  // right
          // noise
          (50, 100, 80, 102),
          (120, 100, 150, 101),
        ],
        frameWidth: 200,
        frameHeight: 200,
      );
      expect(result, isNotNull);
      // Expected corners (normalised to 0..1 with /(w-1), /(h-1)):
      // TL ≈ (20/199, 40/199) ≈ (0.10, 0.20)
      // BR ≈ (180/199, 160/199) ≈ (0.90, 0.80)
      expect(result!.tl.x, closeTo(0.10, 0.02));
      expect(result.tl.y, closeTo(0.20, 0.02));
      expect(result.br.x, closeTo(0.90, 0.02));
      expect(result.br.y, closeTo(0.80, 0.02));
    });

    test('rejects degenerate inputs (all parallel lines)', () {
      // Five parallel horizontals — no way to form a quad.
      final result = HoughQuadCornerSeed.pickQuad(
        segments: const [
          (0, 10, 100, 10),
          (0, 30, 100, 30),
          (0, 50, 100, 50),
          (0, 70, 100, 70),
          (0, 90, 100, 90),
        ],
        frameWidth: 100,
        frameHeight: 100,
      );
      expect(result, isNull);
    });

    test('rejects a quad that covers < 10% of the frame', () {
      // Tiny rectangle, only 10×10, inside a 200×200 frame.
      final result = HoughQuadCornerSeed.pickQuad(
        segments: const [
          (50, 50, 60, 50),
          (50, 60, 60, 60),
          (50, 50, 50, 60),
          (60, 50, 60, 60),
          // Extra perpendiculars so the cluster populates.
          (49, 49, 61, 49),
          (49, 61, 61, 61),
        ],
        frameWidth: 200,
        frameHeight: 200,
      );
      expect(result, isNull);
    });

    test('produces a convex quad for a slightly tilted page', () {
      // Page rotated ~5° around the frame centre. The four edges
      // are still roughly perpendicular so the seeder should
      // handle it.
      final result = HoughQuadCornerSeed.pickQuad(
        segments: const [
          // top (near-horizontal, tilted 5° → rise ~8 over 160)
          (20, 40, 180, 32),
          // bottom
          (20, 160, 180, 152),
          // left (near-vertical, tilted 5°)
          (20, 40, 12, 160),
          // right
          (180, 32, 172, 152),
        ],
        frameWidth: 200,
        frameHeight: 200,
      );
      expect(result, isNotNull);
      // Just a basic convexity check through the normalized corners.
      final tl = result!.tl;
      final br = result.br;
      expect(br.x, greaterThan(tl.x));
      expect(br.y, greaterThan(tl.y));
    });

    test('handles noise by clustering out non-primary lines', () {
      // Real page edges + a random diagonal noise line. The cluster
      // step drops the diagonal because it's neither aligned with
      // the primary nor the perpendicular direction.
      final result = HoughQuadCornerSeed.pickQuad(
        segments: const [
          (30, 50, 170, 50),
          (30, 150, 170, 150),
          (30, 50, 30, 150),
          (170, 50, 170, 150),
          // 45° diagonal noise
          (40, 60, 140, 160),
        ],
        frameWidth: 200,
        frameHeight: 200,
      );
      expect(result, isNotNull);
      expect(result!.tl.x, closeTo(30 / 199, 0.02));
      expect(result.br.y, closeTo(150 / 199, 0.02));
    });
  });
}
