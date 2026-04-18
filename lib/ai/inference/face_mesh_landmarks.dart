/// Canonical landmark indices for the MediaPipe Face Mesh / Face
/// Landmarker 468-point model.
///
/// Status: **scaffold**. The mesh model itself isn't bundled yet —
/// the bundled `face_detection_short` ML Kit detector returns 6
/// landmarks + ~130 contour points. When the mesh model lands and a
/// new `FaceMeshDetectionService` produces a `List<vm.Vector3>` of 468
/// points (or 478 with iris), the polygon helpers below take that
/// list and emit precise eye / iris / lip / tooth outlines.
///
/// Indices are taken from MediaPipe's canonical face mesh topology
/// (https://github.com/google-ai-edge/mediapipe/blob/master/mediapipe/modules/face_geometry/data/canonical_face_model.obj).
/// They are stable across the int8 / fp16 / fp32 variants of the
/// model so the same constants work for whichever flavour we ship.
library;

import 'dart:typed_data';
import 'dart:ui' as ui;

/// 6-point closed polygon around the **left iris**. Available only
/// when the model variant exports the iris module (478-point output).
const List<int> kLeftIrisRing = [474, 475, 476, 477];

/// 6-point closed polygon around the **right iris**.
const List<int> kRightIrisRing = [469, 470, 471, 472];

/// 16-point closed polygon around the **left eye** outer boundary.
/// More precise than ML Kit's single `leftEye` point — eye-brighten
/// can stamp a tight feathered fill instead of a circle that bleeds
/// onto skin.
const List<int> kLeftEyeRing = [
  263, 249, 390, 373, 374, 380, 381, 382,
  362, 398, 384, 385, 386, 387, 388, 466,
];

/// 16-point closed polygon around the **right eye** outer boundary.
const List<int> kRightEyeRing = [
  33, 7, 163, 144, 145, 153, 154, 155,
  133, 173, 157, 158, 159, 160, 161, 246,
];

/// Inner-mouth polygon — the opening between the lips. This is the
/// region teeth-whiten should target (NOT the lips themselves, which
/// the old landmark-only path was desaturating by accident).
const List<int> kInnerMouthRing = [
  78, 95, 88, 178, 87, 14, 317, 402, 318,
  324, 308, 415, 310, 311, 312, 13, 82, 81, 80, 191,
];

/// Full face outline — useful for the slim-face warp (Phase 9f's
/// reshape service can use this instead of the ~36-point ML Kit
/// contour to drive a smoother warp grid).
const List<int> kFaceOval = [
  10, 338, 297, 332, 284, 251, 389, 356, 454, 323, 361, 288,
  397, 365, 379, 378, 400, 377, 152, 148, 176, 149, 150, 136,
  172, 58, 132, 93, 234, 127, 162, 21, 54, 103, 67, 109,
];

/// One landmark in image-pixel coordinates, plus the optional Z that
/// the mesh model produces (relative depth, not metric). The [Offset]
/// is what the mask paths consume; [z] surfaces for depth-aware
/// effects (e.g. relighting) once they ship.
class FaceMeshPoint {
  const FaceMeshPoint({
    required this.x,
    required this.y,
    this.z = 0,
  });
  final double x;
  final double y;
  final double z;

  ui.Offset get offset => ui.Offset(x, y);
}

/// Build a closed [ui.Path] from a list of mesh-point indices. Used by
/// every mask helper below.
ui.Path polygonPath(
  List<FaceMeshPoint> mesh,
  List<int> indices,
) {
  final path = ui.Path();
  if (indices.isEmpty) return path;
  final first = mesh[indices.first];
  path.moveTo(first.x, first.y);
  for (int i = 1; i < indices.length; i++) {
    final p = mesh[indices[i]];
    path.lineTo(p.x, p.y);
  }
  path.close();
  return path;
}

/// Build a `width × height` Float32List alpha mask covering every
/// polygon in [paths]. `1.0` inside, `0.0` outside, with a [feather]
/// pixel falloff at the boundary.
///
/// This is the rasterizer the upcoming portrait-beauty rewrite will
/// use to produce eye / iris / inner-mouth masks from a face-mesh
/// detection. Keeping it in the inference layer (not feature/) means
/// it's isolate-safe — no widgets, no `dart:ui` outside the path
/// math.
///
/// **Implementation notes** (when this gets wired to a real mesh):
///   1. Rasterize [paths] into a `ui.Picture` of size (width, height)
///      with `Paint()..color = Colors.white`.
///   2. `picture.toImage(width, height)` → `toByteData(rawRgba)`.
///   3. Read the R channel as alpha into the Float32List.
///   4. Apply a separable Gaussian blur of radius `feather` for the
///      soft edge.
///
/// Today this returns an all-zero mask so the API surface compiles
/// and tests can pin the shape; the body lights up the moment the
/// mesh detection lands and the portrait-beauty services switch to
/// these polygons.
Float32List buildPolygonMask({
  required List<ui.Path> paths,
  required int width,
  required int height,
  double feather = 2.0,
}) {
  if (width <= 0 || height <= 0) {
    throw ArgumentError('width and height must be > 0');
  }
  return Float32List(width * height);
}
