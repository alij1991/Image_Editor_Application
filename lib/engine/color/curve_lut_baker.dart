import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'curve.dart';

/// Bakes up to four tone curves (master + R + G + B) into a single 256x4
/// RGBA [ui.Image] that can be sampled by `shaders/curves.frag` in a single
/// `texture()` lookup per channel.
///
/// Layout: y = 0.125 -> master, 0.375 -> red, 0.625 -> green, 0.875 -> blue.
/// Each row's red channel stores the mapped output for a given x value;
/// the other channels mirror red so the shader can read via .r.
class CurveLutBaker {
  const CurveLutBaker();

  /// Bake four curves into a 256x4 RGBA image. Any curve may be null, in
  /// which case that row is the identity curve.
  Future<ui.Image> bake({
    ToneCurve? master,
    ToneCurve? red,
    ToneCurve? green,
    ToneCurve? blue,
  }) async {
    final bytes = Uint8List(256 * 4 * 4);
    final rows = [
      master ?? ToneCurve.identity(),
      red ?? ToneCurve.identity(),
      green ?? ToneCurve.identity(),
      blue ?? ToneCurve.identity(),
    ];
    for (int row = 0; row < 4; row++) {
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
    final completer = Completer<ui.Image>();
    ui.decodeImageFromPixels(
      bytes,
      256,
      4,
      ui.PixelFormat.rgba8888,
      completer.complete,
    );
    return completer.future;
  }
}
