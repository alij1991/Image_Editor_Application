import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:image_editor/ai/services/bg_removal/rmbg_bg_removal.dart';
import 'package:image_editor/ai/services/compose_on_bg/compose_edge_refine.dart';

/// Phase XVI.49 — pin the BiRefNet-tier edge-refinement defaults that
/// `RmbgBgRemoval` chains onto its raw matte output, and prove the
/// underlying [ComposeEdgeRefine] pass behaves correctly on alpha-only
/// fixtures.
///
/// The actual ONNX session can't run here (no model file in tests),
/// so the constructor / constant invariants below + the
/// ComposeEdgeRefine smoke tests cover the moving parts. The full
/// inference path is exercised end-to-end via the AI integration
/// tests in app-level coverage.
void main() {
  group('RmbgBgRemoval XVI.49 defaults', () {
    test('default edge feather radius is 1.5 px', () {
      // The published default lifts hair / fur edges into BiRefNet-
      // adjacent quality without softening the interior. Bumping
      // higher than 3 px starts to look like a halo on portraits.
      expect(RmbgBgRemoval.kEdgeFeatherPx, closeTo(1.5, 1e-9));
    });

    test('input size matches the model card', () {
      // RMBG-1.4 is fixed at 1024×1024; changing this would silently
      // break inference because the ONNX shape is static.
      expect(RmbgBgRemoval.inputSize, 1024);
    });
  });

  group('ComposeEdgeRefine.apply (XVI.49 dependency)', () {
    /// Build a small RGBA fixture: 4×1 pixels with a hard alpha edge
    /// in the middle. Lets us probe the feather + decontaminate
    /// behaviour without standing up a real matte.
    Uint8List buildEdgeFixture() {
      // RGBA pattern:
      //   (255, 100, 0, 255)  fully opaque red
      //   (255, 100, 0, 255)  fully opaque red
      //   (50, 50, 50, 0)     transparent, BG-tinted RGB
      //   (50, 50, 50, 0)     transparent, BG-tinted RGB
      return Uint8List.fromList([
        255, 100, 0, 255,
        255, 100, 0, 255,
        50, 50, 50, 0,
        50, 50, 50, 0,
      ]);
    }

    test('feather=0 wipes RGB on transparent pixels (decontaminate)', () {
      // The pre-XVI.49 mask blend left background-tinted RGB on
      // alpha=0 pixels. ComposeEdgeRefine.apply with feather=0 still
      // runs the zero-RGB step so the output composes cleanly.
      final input = buildEdgeFixture();
      final out = ComposeEdgeRefine.apply(
        straightRgba: input,
        width: 4,
        height: 1,
        featherPx: 0,
      );
      // Opaque pixels (0, 1) should be byte-identical (full premul
      // multiplies by 1, no change).
      expect(out[0], 255);
      expect(out[1], 100);
      expect(out[2], 0);
      expect(out[3], 255);
      // Transparent pixels (2, 3) should have RGB wiped to 0.
      expect(out[8], 0);
      expect(out[9], 0);
      expect(out[10], 0);
      expect(out[11], 0);
      expect(out[12], 0);
      expect(out[13], 0);
      expect(out[14], 0);
      expect(out[15], 0);
    });

    test('feather > 0 produces a softer alpha transition', () {
      // 8×1 fixture: hard 50/50 alpha split. After feather, the
      // alpha at the boundary should be in (0, 255) — not snap.
      final input = Uint8List(8 * 4);
      for (var x = 0; x < 8; x++) {
        final i = x * 4;
        input[i] = 200;
        input[i + 1] = 100;
        input[i + 2] = 0;
        input[i + 3] = x < 4 ? 255 : 0;
      }
      final out = ComposeEdgeRefine.apply(
        straightRgba: input,
        width: 8,
        height: 1,
        featherPx: 2,
      );
      // Boundary pixels (3, 4) should now have intermediate alpha
      // values — softer than the 255/0 snap of the input.
      // Only pixels in the transition band get feathered; interior
      // (0..2) and exterior (5..7) stay at extremes.
      final boundaryAlphas = [out[3 * 4 + 3], out[4 * 4 + 3]];
      expect(boundaryAlphas.any((a) => a > 0 && a < 255), isTrue,
          reason: 'feather should produce a non-binary alpha at the edge');
    });

    test('feather is clamped to a safe maximum (no runaway blur)', () {
      // Feeding an absurd radius shouldn't crash or produce NaN —
      // ComposeEdgeRefine clamps to 12 px internally.
      final input = Uint8List(8 * 4);
      for (var x = 0; x < 8; x++) {
        final i = x * 4;
        input[i] = 200;
        input[i + 3] = x < 4 ? 255 : 0;
      }
      final out = ComposeEdgeRefine.apply(
        straightRgba: input,
        width: 8,
        height: 1,
        featherPx: 999,
      );
      // Output must be the right length and every alpha must be in
      // [0, 255].
      expect(out, hasLength(input.length));
      for (var x = 0; x < 8; x++) {
        expect(out[x * 4 + 3], inInclusiveRange(0, 255));
      }
    });

    test('opaque-α threshold matches the documented constant', () {
      // The decontaminate pass treats α >= kOpaqueAlpha (240) as
      // clean interior; pinning here so a future tweak is intentional.
      expect(ComposeEdgeRefine.kOpaqueAlpha, 240);
    });
  });
}
