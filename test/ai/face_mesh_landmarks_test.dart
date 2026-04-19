import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:image_editor/ai/inference/face_mesh_landmarks.dart';

/// Phase C4 scaffold tests. The face-mesh model isn't bundled yet so
/// these pin the index constants and the polygon-helper API surface.
/// When the mesh detection lands, the buildPolygonMask body fills in
/// and a real fixture-based test replaces the all-zero assertion.
void main() {
  List<FaceMeshPoint> grid(int n) {
    // Synthetic 478-point mesh laid out in a square grid so the
    // helpers exercise real coordinates without needing the model.
    final out = <FaceMeshPoint>[];
    const side = 20.0;
    for (int i = 0; i < n; i++) {
      out.add(FaceMeshPoint(
        x: (i % 22).toDouble() * side,
        y: (i ~/ 22).toDouble() * side,
      ));
    }
    return out;
  }

  group('Face-mesh landmark indices', () {
    test('every published ring is non-empty and within 478-point bounds', () {
      const rings = [
        kLeftIrisRing,
        kRightIrisRing,
        kLeftEyeRing,
        kRightEyeRing,
        kInnerMouthRing,
        kFaceOval,
      ];
      for (final ring in rings) {
        expect(ring, isNotEmpty);
        for (final idx in ring) {
          expect(idx, greaterThanOrEqualTo(0));
          expect(idx, lessThan(478));
        }
      }
    });

    test('iris rings are 4 points each', () {
      expect(kLeftIrisRing.length, 4);
      expect(kRightIrisRing.length, 4);
    });

    test('eye outer rings are 16 points each', () {
      expect(kLeftEyeRing.length, 16);
      expect(kRightEyeRing.length, 16);
    });

    test('inner-mouth ring covers ~20 points (lip opening)', () {
      // Tight inner-lip outline — the teeth-whiten target.
      expect(kInnerMouthRing.length, greaterThan(15));
      expect(kInnerMouthRing.length, lessThan(30));
    });

    test('face oval covers ~36 points (head outline)', () {
      expect(kFaceOval.length, greaterThan(30));
      expect(kFaceOval.length, lessThan(50));
    });
  });

  group('FaceMeshPoint', () {
    test('offset projects (x, y) into a ui.Offset', () {
      const p = FaceMeshPoint(x: 12.5, y: 7.25);
      expect(p.offset.dx, 12.5);
      expect(p.offset.dy, 7.25);
    });

    test('z defaults to 0', () {
      const p = FaceMeshPoint(x: 0, y: 0);
      expect(p.z, 0);
    });
  });

  group('polygonPath', () {
    test('empty index list returns an empty path', () {
      final mesh = grid(478);
      final path = polygonPath(mesh, const []);
      expect(path.getBounds().isEmpty, true);
    });

    test('builds a closed path bounding the indexed points', () {
      final mesh = grid(478);
      final path = polygonPath(mesh, kLeftEyeRing);
      final bounds = path.getBounds();
      // The grid spreads points across the canvas — bounds should be
      // non-trivial (more than a few pixels in each axis).
      expect(bounds.width, greaterThan(0));
      expect(bounds.height, greaterThan(0));
    });
  });

  group('buildPolygonMask', () {
    test('rejects non-positive dimensions', () {
      expect(
        () => buildPolygonMask(paths: const [], width: 0, height: 10),
        throwsArgumentError,
      );
      expect(
        () => buildPolygonMask(paths: const [], width: 10, height: -1),
        throwsArgumentError,
      );
    });

    test('returns a Float32List of width*height length', () {
      final mask = buildPolygonMask(paths: const [], width: 8, height: 4);
      expect(mask.length, 32);
      expect(mask, isA<Float32List>());
    });

    test('scaffold returns all-zero (TODO when mesh model lands)', () {
      final mask = buildPolygonMask(paths: const [], width: 4, height: 4);
      for (final v in mask) {
        expect(v, 0);
      }
    });
  });
}
