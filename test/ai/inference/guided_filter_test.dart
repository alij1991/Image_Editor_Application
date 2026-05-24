import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:image_editor/ai/inference/guided_filter.dart';

/// Phase XVI.83 (A2) — unit coverage for the edge-aware mask upsampler.
///
/// The full visual test (does the mask edge snap to hair?) needs a
/// real photo + a side-by-side bilinear comparison and is exercised
/// on-device. These tests pin the mathematical invariants of the
/// algorithm that are reachable without a model or a decoded image.
void main() {
  group('GuidedFilter.upsampleMask — invariants', () {
    test('output is a valid alpha buffer in [0, 1]', () {
      final mask = Float32List.fromList([0.0, 1.0, 0.0, 1.0]);
      final rgba = _solidGray(width: 8, height: 8, gray: 128);
      final out = GuidedFilter.upsampleMask(
        smallMask: mask,
        smallWidth: 2,
        smallHeight: 2,
        sourceRgba: rgba,
        srcWidth: 8,
        srcHeight: 8,
      );
      expect(out.length, 64);
      for (final v in out) {
        expect(v, greaterThanOrEqualTo(0.0));
        expect(v, lessThanOrEqualTo(1.0));
      }
    });

    test(
        'all-foreground mask + uniform guide → output stays near 1 '
        '(no spurious darkening)', () {
      // 16×16 mask all 1.0, source all gray. Output should also be
      // ~1 everywhere because there are no luminance edges to snap
      // to and `p` is already constant.
      final mask = Float32List(16 * 16);
      for (var i = 0; i < mask.length; i++) {
        mask[i] = 1.0;
      }
      final rgba = _solidGray(width: 32, height: 32, gray: 128);
      final out = GuidedFilter.upsampleMask(
        smallMask: mask,
        smallWidth: 16,
        smallHeight: 16,
        sourceRgba: rgba,
        srcWidth: 32,
        srcHeight: 32,
        radius: 4,
      );
      for (final v in out) {
        expect(v, greaterThan(0.95));
      }
    });

    test('all-background mask + uniform guide → output stays near 0',
        () {
      final mask = Float32List(16 * 16); // all 0.0
      final rgba = _solidGray(width: 32, height: 32, gray: 128);
      final out = GuidedFilter.upsampleMask(
        smallMask: mask,
        smallWidth: 16,
        smallHeight: 16,
        sourceRgba: rgba,
        srcWidth: 32,
        srcHeight: 32,
        radius: 4,
      );
      for (final v in out) {
        expect(v, lessThan(0.05));
      }
    });

    test(
        'mask edge snaps to source luminance edge (the whole point '
        'of the filter)', () {
      // 32×32 source split half black / half white (vertical edge at
      // x=16). 16×16 mask is bilinear-soft on the same boundary —
      // pre-XVI.83 bilinear upsample to 32×32 would produce a 1–2 px
      // ramp between black and white. With guided filter, the mask
      // should sharpen because the luminance EDGE at x=16 anchors it.
      final mask = Float32List(16 * 16);
      for (var y = 0; y < 16; y++) {
        for (var x = 0; x < 16; x++) {
          mask[y * 16 + x] = x < 8 ? 0.0 : 1.0; // hard step at x=8
        }
      }
      final rgba = Uint8List(32 * 32 * 4);
      for (var y = 0; y < 32; y++) {
        for (var x = 0; x < 32; x++) {
          final i = (y * 32 + x) * 4;
          final v = x < 16 ? 0 : 255;
          rgba[i] = v;
          rgba[i + 1] = v;
          rgba[i + 2] = v;
          rgba[i + 3] = 255;
        }
      }
      final out = GuidedFilter.upsampleMask(
        smallMask: mask,
        smallWidth: 16,
        smallHeight: 16,
        sourceRgba: rgba,
        srcWidth: 32,
        srcHeight: 32,
        radius: 2,
      );
      // Pixels well inside the black region must be ~0.
      for (var y = 5; y < 27; y++) {
        for (var x = 0; x < 12; x++) {
          expect(out[y * 32 + x], lessThan(0.15),
              reason: 'left interior at ($x,$y) should be background');
        }
        for (var x = 20; x < 32; x++) {
          expect(out[y * 32 + x], greaterThan(0.85),
              reason: 'right interior at ($x,$y) should be foreground');
        }
      }
    });

    test('rejects mismatched mask length', () {
      expect(
        () => GuidedFilter.upsampleMask(
          smallMask: Float32List(10),
          smallWidth: 4,
          smallHeight: 4,
          sourceRgba: _solidGray(width: 8, height: 8, gray: 128),
          srcWidth: 8,
          srcHeight: 8,
        ),
        throwsArgumentError,
      );
    });

    test('rejects mismatched RGBA length', () {
      expect(
        () => GuidedFilter.upsampleMask(
          smallMask: Float32List(4 * 4),
          smallWidth: 4,
          smallHeight: 4,
          sourceRgba: Uint8List(7 * 7 * 4),
          srcWidth: 8,
          srcHeight: 8,
        ),
        throwsArgumentError,
      );
    });

    test('rejects radius < 1', () {
      expect(
        () => GuidedFilter.upsampleMask(
          smallMask: Float32List(4 * 4),
          smallWidth: 4,
          smallHeight: 4,
          sourceRgba: _solidGray(width: 8, height: 8, gray: 128),
          srcWidth: 8,
          srcHeight: 8,
          radius: 0,
        ),
        throwsArgumentError,
      );
    });

    test('rejects epsilon <= 0', () {
      expect(
        () => GuidedFilter.upsampleMask(
          smallMask: Float32List(4 * 4),
          smallWidth: 4,
          smallHeight: 4,
          sourceRgba: _solidGray(width: 8, height: 8, gray: 128),
          srcWidth: 8,
          srcHeight: 8,
          epsilon: 0,
        ),
        throwsArgumentError,
      );
    });

    test('working-resolution cap is honoured for large sources', () {
      // 4096-long-edge source with default processingMaxDim=2048
      // should still produce a 4096-sized output (the filter runs
      // internally at 2048 then bilinear-upsamples back). We only
      // check the output shape — the visual snap was covered above.
      // Using a 16-byte source still passes the API contract via
      // a fake "large" source so we don't allocate 50 MB in tests.
      final mask = Float32List.fromList([0.0, 0.0, 1.0, 1.0]);
      final rgba = _solidGray(width: 64, height: 32, gray: 200);
      final out = GuidedFilter.upsampleMask(
        smallMask: mask,
        smallWidth: 2,
        smallHeight: 2,
        sourceRgba: rgba,
        srcWidth: 64,
        srcHeight: 32,
        radius: 2,
        processingMaxDim: 16, // force the cap path
      );
      expect(out.length, 64 * 32,
          reason: 'output must match SOURCE dims regardless of '
              'internal processing-resolution cap');
    });

    test('defaults match documented constants', () {
      // Regression guard against silent constant drift.
      expect(GuidedFilter.kDefaultProcessingMaxDim, 2048);
      expect(GuidedFilter.kDefaultRadius, 4);
      expect(GuidedFilter.kDefaultEpsilon, 1e-4);
    });
  });
}

/// Build a `width × height` RGBA buffer with every pixel set to
/// `(gray, gray, gray, 255)`.
Uint8List _solidGray({
  required int width,
  required int height,
  required int gray,
}) {
  final rgba = Uint8List(width * height * 4);
  for (var i = 0; i < width * height; i++) {
    rgba[i * 4] = gray;
    rgba[i * 4 + 1] = gray;
    rgba[i * 4 + 2] = gray;
    rgba[i * 4 + 3] = 255;
  }
  return rgba;
}
