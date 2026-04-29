import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:image_editor/engine/color/dehaze_math.dart';

/// Phase XVI.30 — pin the dark-channel-prior dehaze math.
///
/// Pre-XVI.30 the dehaze shader was a midtone-contrast stretch that
/// did nothing on actual hazy photos. The new shader implements a
/// single-pass approximation of He/Sun/Tang 2009: local dark channel
/// + 5-grid atmospheric light + transmission-floored recovery.
///
/// `DehazeMath` mirrors the GLSL math in pure Dart so the algorithm
/// is testable without a GPU fixture; these tests pin the constants
/// (omega, t0, A floor) and the recovery formula. The shader follows.

/// Build a row-major RGBA image filled with a single colour.
Uint8List _solid(int width, int height, int r, int g, int b) {
  final bytes = Uint8List(width * height * 4);
  for (var i = 0; i < bytes.length; i += 4) {
    bytes[i] = r;
    bytes[i + 1] = g;
    bytes[i + 2] = b;
    bytes[i + 3] = 255;
  }
  return bytes;
}

/// Build an image with a hazy-grey background and a darker square in
/// the centre to give the dark-channel computation something non-
/// trivial to find.
Uint8List _hazyWithDarkCentre(int size, int hazeLevel, int darkLevel) {
  final bytes = _solid(size, size, hazeLevel, hazeLevel, hazeLevel);
  final lo = (size * 0.3).round();
  final hi = (size * 0.7).round();
  for (var y = lo; y < hi; y++) {
    for (var x = lo; x < hi; x++) {
      final i = (y * size + x) * 4;
      bytes[i] = darkLevel;
      bytes[i + 1] = darkLevel;
      bytes[i + 2] = darkLevel;
    }
  }
  return bytes;
}

void main() {
  group('DehazeMath constants pinned', () {
    test('omega matches the He paper recommendation', () {
      expect(DehazeMath.kOmega, 0.95);
    });
    test('transmission floor matches the He paper t0', () {
      expect(DehazeMath.kTransMin, 0.10);
    });
    test('atmospheric light black floor avoids div-by-zero', () {
      expect(DehazeMath.kABlackFloor, 0.05);
    });
    test('identity epsilon matches the shader cutoff', () {
      expect(DehazeMath.kIdentityEpsilon, 1e-4);
    });
  });

  group('DehazeMath.darkChannel', () {
    test('uniform white image has dark channel 1.0', () {
      final img = _solid(8, 8, 255, 255, 255);
      final dc = DehazeMath.darkChannel(
        image: img, width: 8, height: 8, cx: 4, cy: 4,
      );
      expect(dc, closeTo(1.0, 1e-6));
    });

    test('uniform black image has dark channel 0.0', () {
      final img = _solid(8, 8, 0, 0, 0);
      final dc = DehazeMath.darkChannel(
        image: img, width: 8, height: 8, cx: 4, cy: 4,
      );
      expect(dc, closeTo(0.0, 1e-6));
    });

    test('saturated red has dark channel 0.0 (G and B are zero)', () {
      // Pure red is the canonical "haze-free" proxy: at least one
      // channel is near-zero, so DCP correctly tags it as clear.
      final img = _solid(8, 8, 255, 0, 0);
      final dc = DehazeMath.darkChannel(
        image: img, width: 8, height: 8, cx: 4, cy: 4,
      );
      expect(dc, closeTo(0.0, 1e-6));
    });

    test('grey 200 has dark channel ≈ 200/255', () {
      // Grey is the canonical "fully hazy" proxy: all 3 channels are
      // high, so DCP correctly tags it as deeply hazy.
      final img = _solid(8, 8, 200, 200, 200);
      final dc = DehazeMath.darkChannel(
        image: img, width: 8, height: 8, cx: 4, cy: 4,
      );
      expect(dc, closeTo(200 / 255, 1e-6));
    });

    test('patch radius reaches into a darker neighbour', () {
      // Centre is grey 220, but a 4x4 patch in the top-left corner is
      // grey 50. With radius 5 the dark channel at (3,3) should pick
      // up the dark patch.
      final img = _solid(16, 16, 220, 220, 220);
      for (var y = 0; y < 4; y++) {
        for (var x = 0; x < 4; x++) {
          final i = (y * 16 + x) * 4;
          img[i] = 50;
          img[i + 1] = 50;
          img[i + 2] = 50;
        }
      }
      final dc = DehazeMath.darkChannel(
        image: img, width: 16, height: 16, cx: 3, cy: 3, radius: 5,
      );
      expect(dc, closeTo(50 / 255, 1e-6));
    });
  });

  group('DehazeMath.atmosphericLight', () {
    test('uniform image returns its colour (above black floor)', () {
      final img = _solid(32, 32, 220, 220, 220);
      final a = DehazeMath.atmosphericLight(
        image: img, width: 32, height: 32,
      );
      expect(a[0], closeTo(220 / 255, 1e-6));
      expect(a[1], closeTo(220 / 255, 1e-6));
      expect(a[2], closeTo(220 / 255, 1e-6));
    });

    test('black image is floored to kABlackFloor', () {
      final img = _solid(32, 32, 0, 0, 0);
      final a = DehazeMath.atmosphericLight(
        image: img, width: 32, height: 32,
      );
      expect(a[0], DehazeMath.kABlackFloor);
      expect(a[1], DehazeMath.kABlackFloor);
      expect(a[2], DehazeMath.kABlackFloor);
    });

    test('picks the brightest of 5 grid samples', () {
      // Image is dark grey 60; only the top-centre pixel is white.
      // The 5-grid should land on top centre and pick it.
      final img = _solid(32, 32, 60, 60, 60);
      // top centre at (0.5, 0.05) → x=15 or 16, y=1 or 2.
      // Paint a 4x4 white patch around (16, 1) to make sure the
      // sampler hits it regardless of rounding.
      for (var y = 0; y < 4; y++) {
        for (var x = 14; x < 18; x++) {
          final i = (y * 32 + x) * 4;
          img[i] = 255;
          img[i + 1] = 255;
          img[i + 2] = 255;
        }
      }
      final a = DehazeMath.atmosphericLight(
        image: img, width: 32, height: 32,
      );
      expect(a[0], closeTo(1.0, 1e-6));
      expect(a[1], closeTo(1.0, 1e-6));
      expect(a[2], closeTo(1.0, 1e-6));
    });
  });

  group('DehazeMath.applyPixel', () {
    test('amount=0 returns the source pixel unchanged', () {
      final out = DehazeMath.applyPixel(
        r: 0.6, g: 0.7, b: 0.8,
        dc: 0.3,
        a: [0.95, 0.95, 0.95],
        amount: 0,
      );
      expect(out[0], closeTo(0.6, 1e-9));
      expect(out[1], closeTo(0.7, 1e-9));
      expect(out[2], closeTo(0.8, 1e-9));
    });

    test('|amount| below identity epsilon short-circuits', () {
      final out = DehazeMath.applyPixel(
        r: 0.5, g: 0.5, b: 0.5,
        dc: 0.5,
        a: [1.0, 1.0, 1.0],
        amount: 5e-5,
      );
      expect(out[0], closeTo(0.5, 1e-9));
    });

    test('clear pixel (dc=0) is unchanged at any amount', () {
      // dc=0 → t = 1.0 → J = (I - A) + A = I → mix(I, I, amount) = I.
      final out = DehazeMath.applyPixel(
        r: 0.4, g: 0.2, b: 0.1,
        dc: 0,
        a: [0.95, 0.95, 0.95],
        amount: 1.0,
      );
      expect(out[0], closeTo(0.4, 1e-6));
      expect(out[1], closeTo(0.2, 1e-6));
      expect(out[2], closeTo(0.1, 1e-6));
    });

    test('hazy grey pixel under positive amount moves toward black', () {
      // I=0.85, A=0.95, dc=0.85.
      //   aAvg = 0.95
      //   t = 1 - 0.95 * 0.85/0.95 = 0.15  (above the 0.10 floor)
      //   J = (0.85 - 0.95)/0.15 + 0.95 = -0.6667 + 0.95 ≈ 0.2833
      //   amount=1 → output = J ≈ 0.283
      // The recovery is large because the pixel is deeply hazy; the
      // dehazed value lands well below the input but still positive.
      final out = DehazeMath.applyPixel(
        r: 0.85, g: 0.85, b: 0.85,
        dc: 0.85,
        a: [0.95, 0.95, 0.95],
        amount: 1.0,
      );
      expect(out[0], closeTo(0.2833, 1e-3));
      expect(out[1], closeTo(0.2833, 1e-3));
      expect(out[2], closeTo(0.2833, 1e-3));
      // And below the source — recovery moves toward "darker dark".
      expect(out[0], lessThan(0.85));
    });

    test('negative amount mixes toward atmospheric light', () {
      // amount=-1 → output = A regardless of input.
      final a = [0.9, 0.85, 0.8];
      final out = DehazeMath.applyPixel(
        r: 0.2, g: 0.3, b: 0.4,
        dc: 0.2,
        a: a,
        amount: -1.0,
      );
      expect(out[0], closeTo(0.9, 1e-6));
      expect(out[1], closeTo(0.85, 1e-6));
      expect(out[2], closeTo(0.8, 1e-6));
    });

    test('transmission floor caps the recovery boost', () {
      // dc large enough that 1 - omega*dc/Aavg < t0. Pin that the
      // floor is what the formula uses, not the negative value.
      // dc=1.0, A=1.0 → t = 1 - 0.95 = 0.05 → clamped to 0.10.
      // Expected J for I=0.5, A=1.0: (0.5-1)/0.10 + 1 = -4.
      // Clamped to 0 in output.
      final out = DehazeMath.applyPixel(
        r: 0.5, g: 0.5, b: 0.5,
        dc: 1.0,
        a: [1.0, 1.0, 1.0],
        amount: 1.0,
      );
      expect(out[0], closeTo(0.0, 1e-6));
    });

    test('recovery is monotonic in amount (positive)', () {
      // For a hazy pixel, more amount → more recovery → output moves
      // monotonically away from I.
      final outs = [
        for (final a in [0.0, 0.25, 0.5, 0.75, 1.0])
          DehazeMath.applyPixel(
            r: 0.7, g: 0.7, b: 0.7,
            dc: 0.6,
            a: [0.95, 0.95, 0.95],
            amount: a,
          )[0],
      ];
      // amount=0 must equal source.
      expect(outs.first, closeTo(0.7, 1e-9));
      // Monotonic decreasing (J < I in this setup).
      for (var i = 1; i < outs.length; i++) {
        expect(
          outs[i],
          lessThanOrEqualTo(outs[i - 1] + 1e-9),
          reason: 'output must move monotonically with positive amount',
        );
      }
    });
  });

  group('DehazeMath end-to-end roundtrip on a hazy fixture', () {
    test('positive amount lifts contrast on a synthetic hazy frame', () {
      // Hazy grey background (220), darker centre square (140). A
      // realistic hazy fixture: low contrast everywhere, all channels
      // high.
      final img = _hazyWithDarkCentre(32, 220, 140);
      final a = DehazeMath.atmosphericLight(
        image: img, width: 32, height: 32,
      );
      // The brightest 5-grid sample is grey 220, so A ≈ 0.863.
      expect(a[0], closeTo(220 / 255, 0.01));

      // Centre dark channel: a 5x5 patch entirely inside the darker
      // square at (16, 16) — values are all 140.
      final dcCenter = DehazeMath.darkChannel(
        image: img, width: 32, height: 32, cx: 16, cy: 16,
      );
      expect(dcCenter, closeTo(140 / 255, 1e-6));

      // Edge dark channel: a 5x5 patch in the top-left grey area.
      final dcEdge = DehazeMath.darkChannel(
        image: img, width: 32, height: 32, cx: 4, cy: 4,
      );
      expect(dcEdge, closeTo(220 / 255, 1e-6));

      // Recovery on the centre pixel under amount=+1 should drop the
      // value below the source (lifted contrast → darker dark).
      final centerOut = DehazeMath.applyPixel(
        r: 140 / 255, g: 140 / 255, b: 140 / 255,
        dc: dcCenter, a: a, amount: 1.0,
      );
      expect(centerOut[0], lessThan(140 / 255 - 0.05));

      // Recovery on the edge pixel: dc=A → near-saturated transmission
      // floor → J ≈ A. Output stays near the source.
      final edgeOut = DehazeMath.applyPixel(
        r: 220 / 255, g: 220 / 255, b: 220 / 255,
        dc: dcEdge, a: a, amount: 1.0,
      );
      expect((edgeOut[0] - 220 / 255).abs(), lessThan(0.05));
    });
  });
}
