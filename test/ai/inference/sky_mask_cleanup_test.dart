import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:image_editor/ai/inference/sky_mask_cleanup.dart';

void main() {
  group('keepSkyComponentsTouchingTop', () {
    test('drops a blob disconnected from the top, keeps top sky', () {
      // 10x10. Top 3 rows = sky (touches row 0). A 2x2 blob at
      // (5,6) is disconnected (the tulip bleed). Should be dropped.
      const w = 10, h = 10;
      final mask = Float32List(w * h);
      for (var y = 0; y < 3; y++) {
        for (var x = 0; x < w; x++) {
          mask[y * w + x] = 1.0;
        }
      }
      // Disconnected blob.
      for (var y = 6; y < 8; y++) {
        for (var x = 5; x < 7; x++) {
          mask[y * w + x] = 1.0;
        }
      }
      final res = keepSkyComponentsTouchingTop(mask, width: w, height: h);
      expect(res.keptTouchedTop, isTrue);
      expect(res.droppedPixels, 4); // the 2x2 blob
      // Top sky survives.
      expect(mask[0], 1.0);
      expect(mask[2 * w + 0], 1.0);
      // Blob gone.
      expect(mask[6 * w + 5], 0.0);
      expect(mask[7 * w + 6], 0.0);
    });

    test('keeps BOTH halves of a split sky (head splitting the top)',
        () {
      // 10x10. Sky on the left columns 0-3 and right columns 6-9 for
      // the top 4 rows, with a "head" gap in columns 4-5. Both halves
      // reach the top, so both must survive.
      const w = 10, h = 10;
      final mask = Float32List(w * h);
      for (var y = 0; y < 4; y++) {
        for (var x = 0; x < w; x++) {
          if (x < 4 || x >= 6) mask[y * w + x] = 1.0;
        }
      }
      final res = keepSkyComponentsTouchingTop(mask, width: w, height: h);
      expect(res.keptTouchedTop, isTrue);
      expect(res.droppedPixels, 0); // both halves touch top
      expect(mask[0], 1.0); // left half
      expect(mask[9], 1.0); // right half
    });

    test('safe no-op when nothing touches the top edge', () {
      // A blob entirely in the middle, never touching row 0.
      const w = 10, h = 10;
      final mask = Float32List(w * h);
      for (var y = 4; y < 7; y++) {
        for (var x = 4; x < 7; x++) {
          mask[y * w + x] = 1.0;
        }
      }
      final res = keepSkyComponentsTouchingTop(mask, width: w, height: h);
      expect(res.keptTouchedTop, isFalse);
      expect(res.droppedPixels, 0);
      // Mask untouched (fallback).
      expect(mask[5 * w + 5], 1.0);
    });

    test('preserves soft feather within a kept component', () {
      // Top region with a feathered edge (0.7 alpha) — must survive
      // intact (we only zero whole dropped components, never touch
      // alpha inside kept ones).
      const w = 6, h = 6;
      final mask = Float32List(w * h);
      for (var x = 0; x < w; x++) {
        mask[x] = 1.0; // row 0 solid
        mask[w + x] = 0.7; // row 1 feathered
      }
      final res = keepSkyComponentsTouchingTop(mask, width: w, height: h);
      expect(res.keptTouchedTop, isTrue);
      expect(mask[w + 0], closeTo(0.7, 1e-6));
    });

    test('throws on size mismatch', () {
      expect(
        () => keepSkyComponentsTouchingTop(
          Float32List(4),
          width: 3,
          height: 3,
        ),
        throwsArgumentError,
      );
    });

    test('large disconnected band below the sky is dropped', () {
      // Reproduces the tulip-bench bleed shape: a full-width sky band
      // at top (rows 0-2) and a full-width bleed band in the middle
      // (rows 5-6) separated by non-sky. The bleed band is LARGE but
      // disconnected → must still be dropped (largest-component would
      // keep it; the touches-top rule removes it).
      const w = 20, h = 10;
      final mask = Float32List(w * h);
      for (var x = 0; x < w; x++) {
        for (var y = 0; y < 3; y++) {
          mask[y * w + x] = 1.0; // top sky
        }
        for (var y = 5; y < 7; y++) {
          mask[y * w + x] = 1.0; // bleed band (disconnected)
        }
      }
      final res = keepSkyComponentsTouchingTop(mask, width: w, height: h);
      expect(res.keptTouchedTop, isTrue);
      expect(res.droppedPixels, w * 2); // the two bleed rows
      expect(mask[0], 1.0); // sky kept
      expect(mask[5 * w + 10], 0.0); // bleed gone
    });
  });
}
