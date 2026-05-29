import 'package:flutter_test/flutter_test.dart';

import 'package:image_editor/ai/services/bg_removal/image_io.dart';

/// XVI.104 — pins the decode-tier policy for full-frame AI outputs.
///
/// Background: a service that returns a FULL-FRAME `ui.Image`
/// (a layer/cutout composited onto the editor canvas at source
/// resolution) must decode the source at native quality. If it
/// decodes lower, the layer painter / shader renderer bilinear-
/// upscales the low-res cutout onto the canvas and the full-res
/// export → visible blur. This was the XVI.103 denoise/deblur
/// regression; the XVI.104 audit found the same shape in MODNet,
/// RVM, face restore, and hair/clothes recolour, all now wired to
/// [BgRemovalImageIo.fullFrameDecodeDimension].
///
/// These assertions guard the POLICY CONSTANT. The per-service
/// wiring (each decode call passing `maxDimension:
/// fullFrameDecodeDimension`) is verified by code review + the
/// on-device decode-dimension log line; the ORT/LiteRT inference
/// path can't run under `flutter test`.
void main() {
  group('full-frame decode policy (XVI.104)', () {
    test('fullFrameDecodeDimension aliases native quality', () {
      expect(
        BgRemovalImageIo.fullFrameDecodeDimension,
        BgRemovalImageIo.nativeQualityDecodeDimension,
      );
    });

    test('full-frame tier is above the old 1024 default', () {
      // The XVI.103/104 bug was decoding full-frame output at the
      // 1024 default. The policy tier must exceed it.
      expect(
        BgRemovalImageIo.fullFrameDecodeDimension,
        greaterThan(BgRemovalImageIo.maxDecodeDimension),
      );
    });

    test('full-frame tier is at least preview quality', () {
      expect(
        BgRemovalImageIo.fullFrameDecodeDimension,
        greaterThanOrEqualTo(BgRemovalImageIo.previewQualityDecodeDimension),
      );
    });

    test('decode tiers are strictly ordered', () {
      expect(
        BgRemovalImageIo.maxDecodeDimension,
        lessThan(BgRemovalImageIo.previewQualityDecodeDimension),
      );
      expect(
        BgRemovalImageIo.previewQualityDecodeDimension,
        lessThan(BgRemovalImageIo.nativeQualityDecodeDimension),
      );
    });

    test('native quality is 4096 (current iPhone main-camera tier)', () {
      expect(BgRemovalImageIo.nativeQualityDecodeDimension, 4096);
    });
  });
}
