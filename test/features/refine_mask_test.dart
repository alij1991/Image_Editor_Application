import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';

import 'package:image_editor/features/editor/presentation/widgets/refine_mask_overlay.dart';

/// Behaviour tests for the refine-mask flow.
///
/// The full RefineMaskOverlay UI runs custom painters that read the
/// source / cutout images on every frame; we exercise it on device
/// rather than in flutter_test (no real GPU). Here we cover the
/// pieces that have a tight, isolated contract:
///   - The [RefineMaskResult] data class.
///   - Stroke math on the mask renderer is integration-tested via
///     `EditorSession.replaceCutoutImage` round-trips on device.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<ui.Image> tinySolidImage(int w, int h, int rgba) async {
    final pixels = Uint8List(w * h * 4);
    for (int i = 0; i < w * h; i++) {
      pixels[i * 4 + 0] = (rgba >> 24) & 0xff;
      pixels[i * 4 + 1] = (rgba >> 16) & 0xff;
      pixels[i * 4 + 2] = (rgba >> 8) & 0xff;
      pixels[i * 4 + 3] = rgba & 0xff;
    }
    final completer = Completer<ui.Image>();
    ui.decodeImageFromPixels(
      pixels,
      w,
      h,
      ui.PixelFormat.rgba8888,
      completer.complete,
    );
    return completer.future;
  }

  group('RefineMaskResult', () {
    test('exposes layerId and image', () async {
      final image = await tinySolidImage(2, 2, 0xff112233);
      try {
        final r = RefineMaskResult(layerId: 'abc', image: image);
        expect(r.layerId, 'abc');
        expect(r.image, image);
      } finally {
        image.dispose();
      }
    });

    test('layerId and image are required (compile-time positional safety)',
        () async {
      // Pin the constructor shape — if this stops compiling, callers
      // need to update.
      final image = await tinySolidImage(1, 1, 0xff000000);
      try {
        final r = RefineMaskResult(layerId: '', image: image);
        expect(r, isA<RefineMaskResult>());
      } finally {
        image.dispose();
      }
    });
  });
}
