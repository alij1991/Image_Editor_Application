import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:image_editor/engine/color/curve.dart';
import 'package:image_editor/engine/color/curve_lut_baker.dart';

/// Phase V.6 tests for `CurveLutBaker` + the extracted
/// `bakeToneCurveLutBytes` pure helper. XVI.24 expanded the LUT from
/// 256×4 (master + R + G + B) to 256×5 by adding a luma row.
///
/// The tests pin:
///   1. **Byte-gen correctness** — the identity curve lands on
///      passthrough output, s-curve lands on the expected S shape.
///   2. **Isolate-vs-main equivalence** — `bake` and `bakeInIsolate`
///      produce byte-identical output for the same inputs. Catches
///      a silent divergence if the pure helper is ever edited in
///      only one of its two call sites.
///   3. **Serialization roundtrip** — `compute()`'s isolate boundary
///      requires `BakeToneCurveLutArgs` to copy cleanly. A bake that
///      reaches the worker and returns a 5120-byte output is the
///      end-to-end pin.
///   4. **`ui.Image` output** — the final `ui.Image` has the expected
///      256×5 dimensions on both paths.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const baker = CurveLutBaker();

  /// Helper: peek at the red-channel byte at row `channel`
  /// (0=master, 1=R, 2=G, 3=B, 4=luma), column `x` (0..255). All
  /// three RGB bytes are mirrored for the shader so reading `.r`
  /// from any of them works.
  int peek(Uint8List lut, int channel, int x) {
    return lut[(channel * 256 + x) * 4];
  }

  group('bakeToneCurveLutBytes', () {
    test('output size is 256 * 5 * 4 = 5120 bytes (XVI.24 luma row)', () {
      final bytes = bakeToneCurveLutBytes(const BakeToneCurveLutArgs());
      expect(bytes.length, 5120);
    });

    test('all-null args fill every row with identity', () {
      // Identity → output[x] ≈ x for every channel, every row.
      final bytes = bakeToneCurveLutBytes(const BakeToneCurveLutArgs());
      for (int channel = 0; channel < 5; channel++) {
        for (final x in [0, 32, 64, 128, 192, 255]) {
          expect(peek(bytes, channel, x), x,
              reason: 'channel=$channel x=$x — identity must passthrough');
        }
      }
    });

    test('alpha channel is always 255', () {
      final bytes = bakeToneCurveLutBytes(const BakeToneCurveLutArgs());
      for (int channel = 0; channel < 5; channel++) {
        for (int x = 0; x < 256; x++) {
          final alpha = bytes[(channel * 256 + x) * 4 + 3];
          expect(alpha, 255);
        }
      }
    });

    test('RGB bytes are mirrored for shader .r sampling', () {
      // Pick a non-identity curve so the output bytes are non-zero
      // across the row — identity happens to equal on every channel
      // by arithmetic, so the mirror invariant needs a curve that
      // actually shifts the value.
      final bytes = bakeToneCurveLutBytes(const BakeToneCurveLutArgs(
        master: [
          [0, 0],
          [0.5, 0.75],
          [1, 1],
        ],
      ));
      for (int x = 0; x < 256; x++) {
        final i = (0 * 256 + x) * 4;
        expect(bytes[i], bytes[i + 1], reason: 'r==g at x=$x');
        expect(bytes[i], bytes[i + 2], reason: 'r==b at x=$x');
      }
    });

    test('s-curve hits expected shape on master row', () {
      final bytes = bakeToneCurveLutBytes(const BakeToneCurveLutArgs(
        master: [
          [0, 0],
          [0.25, 0.1],
          [0.75, 0.9],
          [1, 1],
        ],
      ));
      // Endpoints preserved.
      expect(peek(bytes, 0, 0), 0);
      expect(peek(bytes, 0, 255), 255);
      // Shadow quarter darkened, highlight quarter brightened.
      final shadow = peek(bytes, 0, 64); // x ~ 0.25
      final highlight = peek(bytes, 0, 192); // x ~ 0.75
      expect(shadow, lessThan(64),
          reason: 's-curve pulls shadows down: peek($shadow) < 64 expected');
      expect(highlight, greaterThan(192),
          reason: 's-curve pushes highlights up: peek($highlight) > 192');
    });

    test('per-channel curves land on their own rows only', () {
      // Only red row has a non-identity curve; master + green +
      // blue + luma stay identity.
      final bytes = bakeToneCurveLutBytes(const BakeToneCurveLutArgs(
        red: [
          [0, 0],
          [0.5, 1], // red doubles in shadows
          [1, 1],
        ],
      ));
      // Master + green + blue + luma rows are identity → peek(r,
      // 128) == 128.
      expect(peek(bytes, 0, 128), 128);
      expect(peek(bytes, 2, 128), 128);
      expect(peek(bytes, 3, 128), 128);
      expect(peek(bytes, 4, 128), 128, reason: 'luma row stays identity');
      // Red row at x=128 is pushed much brighter than identity.
      expect(peek(bytes, 1, 128), greaterThan(200));
    });

    test('luma row hits the 5th LUT row (XVI.24)', () {
      // Author a luma curve that maps mid-grey 0.5 → 0.8 (~brighten
      // mids). The other four rows stay identity. The shader then
      // applies the luma curve multiplicatively in
      // shaders/curves.frag, but the LUT itself just stores the
      // mapping.
      final bytes = bakeToneCurveLutBytes(const BakeToneCurveLutArgs(
        luma: [
          [0, 0],
          [0.5, 0.8],
          [1, 1],
        ],
      ));
      // Rows 0-3 untouched.
      for (int row = 0; row < 4; row++) {
        expect(peek(bytes, row, 128), 128,
            reason: 'row $row should be identity, was ${peek(bytes, row, 128)}');
      }
      // Row 4 (luma) at x=128 (~mid-grey) reads back closer to 0.8 *
      // 255 = 204 than the identity 128.
      expect(peek(bytes, 4, 128), greaterThan(180),
          reason: 'luma row maps mid-grey toward the brighter target');
    });
  });

  group('CurveLutBaker.bake vs bakeInIsolate equivalence', () {
    test('identity bake produces a 256×5 ui.Image on both paths',
        () async {
      final onMain = await baker.bake();
      expect(onMain.width, 256);
      expect(onMain.height, 5); // XVI.24
      onMain.dispose();

      final onWorker = await baker.bakeInIsolate();
      expect(onWorker.width, 256);
      expect(onWorker.height, 5); // XVI.24
      onWorker.dispose();
    });

    test('identical inputs produce identical byte output', () async {
      // `bake` on main + `bakeInIsolate` through `compute()` must
      // produce byte-for-byte identical output; a silent divergence
      // (e.g. the pure helper getting edited in only one path) would
      // trip this test.
      final curve = ToneCurve.sCurve(0.2);
      final a = await baker.bake(master: curve);
      final b = await baker.bakeInIsolate(master: curve);

      final ba = (await a.toByteData())!.buffer.asUint8List();
      final bb = (await b.toByteData())!.buffer.asUint8List();
      a.dispose();
      b.dispose();

      expect(ba.length, bb.length);
      for (int i = 0; i < ba.length; i++) {
        expect(ba[i], bb[i],
            reason: 'byte $i differs: main=${ba[i]} vs worker=${bb[i]}');
      }
    });

    test('per-channel curves round-trip through the isolate path',
        () async {
      final image = await baker.bakeInIsolate(
        red: ToneCurve([
          const CurvePoint(0, 0),
          const CurvePoint(0.5, 0.8),
          const CurvePoint(1, 1),
        ]),
        green: ToneCurve.sCurve(0.1),
      );
      expect(image.width, 256);
      expect(image.height, 5); // XVI.24
      image.dispose();
    });
  });

  group('BakeToneCurveLutArgs serialization', () {
    test('args with all five channels populate the full byte grid',
        () async {
      const args = BakeToneCurveLutArgs(
        master: [
          [0, 0],
          [1, 1]
        ],
        red: [
          [0, 0],
          [1, 1]
        ],
        green: [
          [0, 0],
          [1, 1]
        ],
        blue: [
          [0, 0],
          [1, 1]
        ],
        luma: [
          [0, 0],
          [1, 1]
        ],
      );
      final bytes = bakeToneCurveLutBytes(args);
      expect(bytes.length, 5120); // XVI.24
      // All five identity rows → x at column x.
      for (int channel = 0; channel < 5; channel++) {
        expect(peek(bytes, channel, 100), 100);
      }
    });
  });
}
