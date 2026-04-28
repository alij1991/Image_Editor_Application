import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart' show compute;

import 'curve.dart';

/// Bakes up to five tone curves (master + R + G + B + Luma) into a
/// single 256x5 RGBA [ui.Image] that can be sampled by
/// `shaders/curves.frag` in a single `texture()` lookup per channel.
///
/// Layout (y center per row, with `(row + 0.5)/5.0`):
///   row 0 → master, row 1 → red, row 2 → green, row 3 → blue,
///   row 4 → luma (XVI.24, applied post-master+RGB on perceptual Y).
/// Each row's red channel stores the mapped output for a given x value;
/// the other channels mirror red so the shader can read via .r.
///
/// ## Phase V.6 worker-isolate path
///
/// The 1024 Hermite cubic evaluations that drive the byte-gen step were
/// stealing ~0.5–2 ms of main-thread time per bake on mid-range Android
/// — multiplied across a sustained curve drag at 60 FPS, that shows up
/// as frame-time jitter in the preview. [bakeInIsolate] pushes the byte
/// generation into a `compute()` worker; [bake] stays on the main
/// isolate for tests and callers who don't have a `TestWidgetsFlutterBinding`
/// scheduled worker available. `ui.decodeImageFromPixels` itself is
/// always invoked on the main isolate — the engine's codec path is
/// main-bound and the `ui.Image` result isn't serializable across
/// isolates anyway.
class CurveLutBaker {
  const CurveLutBaker();

  /// Bake five curves into a 256x5 RGBA image. Any curve may be null,
  /// in which case that row is the identity curve. Runs synchronously
  /// on the calling isolate — the main cost is ~0.5 ms of Hermite
  /// evaluation on mobile. See [bakeInIsolate] for the `compute()`-
  /// backed path used by the editor session during sustained drags.
  Future<ui.Image> bake({
    ToneCurve? master,
    ToneCurve? red,
    ToneCurve? green,
    ToneCurve? blue,
    ToneCurve? luma,
  }) {
    final bytes = bakeToneCurveLutBytes(BakeToneCurveLutArgs(
      master: _points(master),
      red: _points(red),
      green: _points(green),
      blue: _points(blue),
      luma: _points(luma),
    ));
    return _bytesToImage(bytes);
  }

  /// Phase V.6: same contract as [bake], but the 1024-point Hermite
  /// evaluation runs in a worker isolate via `compute()`. The
  /// [ui.decodeImageFromPixels] step still runs on the calling isolate
  /// — the engine's codec path requires it.
  ///
  /// Net main-thread savings: ~0.5–2 ms of Hermite math per bake. Because
  /// `compute()` spawns a fresh isolate per call (~5–10 ms setup on
  /// Android), callers driving many bakes per second MUST coalesce
  /// upstream. `EditorSession._bakeCurveLut` does that via a single-slot
  /// pending-bake queue: at most one bake is in flight, at most one is
  /// queued.
  Future<ui.Image> bakeInIsolate({
    ToneCurve? master,
    ToneCurve? red,
    ToneCurve? green,
    ToneCurve? blue,
    ToneCurve? luma,
  }) async {
    final bytes = await compute(
      bakeToneCurveLutBytes,
      BakeToneCurveLutArgs(
        master: _points(master),
        red: _points(red),
        green: _points(green),
        blue: _points(blue),
        luma: _points(luma),
      ),
    );
    return _bytesToImage(bytes);
  }

  static List<List<double>>? _points(ToneCurve? curve) {
    if (curve == null) return null;
    return [for (final p in curve.points) [p.x, p.y]];
  }

  static Future<ui.Image> _bytesToImage(Uint8List bytes) {
    final completer = Completer<ui.Image>();
    ui.decodeImageFromPixels(
      bytes,
      256,
      5, // XVI.24: 5 rows = master / red / green / blue / luma.
      ui.PixelFormat.rgba8888,
      completer.complete,
    );
    return completer.future;
  }
}

/// Isolate-serializable argument bundle for [bakeToneCurveLutBytes].
///
/// Each channel is encoded as a list of `[x, y]` pairs — primitive
/// value types that cross `compute()`'s isolate boundary without
/// serialization surprises. A `null` channel is the identity curve,
/// matching the pre-V.6 `CurveLutBaker.bake` semantics.
class BakeToneCurveLutArgs {
  const BakeToneCurveLutArgs({
    this.master,
    this.red,
    this.green,
    this.blue,
    this.luma,
  });

  final List<List<double>>? master;
  final List<List<double>>? red;
  final List<List<double>>? green;
  final List<List<double>>? blue;
  final List<List<double>>? luma;
}

/// Phase V.6 pure helper: generate the 256×5×RGBA byte layout for a
/// tone-curve LUT (XVI.24 added the 5th row for the luma curve).
/// Top-level function (not a method) so `compute()` can hand it to a
/// worker isolate.
///
/// Output size: `256 * 5 * 4 = 5120` bytes. Layout matches the
/// [CurveLutBaker] class docs — row 0 = master, 1 = red, 2 = green,
/// 3 = blue, 4 = luma. Each row's RGB channels all hold the mapped
/// output byte (shader reads via `.r`); alpha is always 255.
///
/// Exposed both to the isolate path and to equivalence tests that
/// pin the bake against the pre-V.6 reference implementation.
Uint8List bakeToneCurveLutBytes(BakeToneCurveLutArgs args) {
  final bytes = Uint8List(256 * 5 * 4);
  final rows = <ToneCurve>[
    _toCurve(args.master) ?? ToneCurve.identity(),
    _toCurve(args.red) ?? ToneCurve.identity(),
    _toCurve(args.green) ?? ToneCurve.identity(),
    _toCurve(args.blue) ?? ToneCurve.identity(),
    _toCurve(args.luma) ?? ToneCurve.identity(),
  ];
  for (int row = 0; row < 5; row++) {
    final curve = rows[row];
    for (int x = 0; x < 256; x++) {
      final input = x / 255.0;
      final output = (curve.evaluate(input).clamp(0.0, 1.0) * 255).round();
      final i = (row * 256 + x) * 4;
      bytes[i + 0] = output;
      bytes[i + 1] = output;
      bytes[i + 2] = output;
      bytes[i + 3] = 255;
    }
  }
  return bytes;
}

ToneCurve? _toCurve(List<List<double>>? points) {
  if (points == null) return null;
  return ToneCurve([for (final p in points) CurvePoint(p[0], p[1])]);
}
