import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' show ColorFilter;

import 'edit_op_type.dart';
import 'edit_operation.dart';
import 'edit_pipeline.dart';

/// Folds every matrix-composable operation in an [EditPipeline] into a
/// single 5x4 color matrix applied in one shader pass.
///
/// Flutter's `ColorFilter.matrix()` takes a 20-element row-major 5x4
/// matrix: four rows (r, g, b, a) of five coefficients (r, g, b, a, bias).
/// Composing multiple color ops via matrix multiplication means the shader
/// can apply arbitrarily many color adjustments in one pass, preserving the
/// blueprint's "<5 ms full color pipeline" target.
///
/// Non-matrix ops ([EditOperation.needsShaderPass]) are left in the pipeline
/// and rendered in subsequent passes by [ShaderRenderer] (Phase 2).
class MatrixComposer {
  const MatrixComposer();

  /// Identity 5x4 matrix.
  static Float32List identity() {
    final m = Float32List(20);
    m[0] = 1;
    m[6] = 1;
    m[12] = 1;
    m[18] = 1;
    return m;
  }

  /// Compose every matrix-composable op in [pipeline] into a single matrix.
  /// Disabled ops are skipped.
  Float32List compose(EditPipeline pipeline) {
    var acc = identity();
    for (final op in pipeline.operations) {
      if (!op.enabled) continue;
      if (!op.isMatrixComposable) continue;
      final m = _matrixFor(op);
      if (m != null) acc = multiply(m, acc);
    }
    return acc;
  }

  /// Return the 5x4 matrix for a single matrix-composable op, or null if
  /// [op] is not matrix-expressible.
  Float32List? _matrixFor(EditOperation op) {
    switch (op.type) {
      case EditOpType.brightness:
        return brightness(op.doubleParam('value'));
      case EditOpType.contrast:
        return contrast(op.doubleParam('value'));
      case EditOpType.saturation:
        return saturation(op.doubleParam('value'));
      case EditOpType.hue:
        return hue(op.doubleParam('value'));
      case EditOpType.exposure:
        return exposure(op.doubleParam('value'));
      case EditOpType.channelMixer:
        return channelMixer(
          op.doubleListParam('red'),
          op.doubleListParam('green'),
          op.doubleListParam('blue'),
        );
    }
    return null;
  }

  // --- Matrix primitives (exposed as static so tests can hit them directly) ---

  /// Brightness is additive. [value] in [-1, 1].
  static Float32List brightness(double value) {
    final m = identity();
    m[4] = value;
    m[9] = value;
    m[14] = value;
    return m;
  }

  /// Contrast scales around 0.5. [value] in [-1, 1].
  static Float32List contrast(double value) {
    final scale = 1.0 + value;
    final bias = 0.5 * (1.0 - scale);
    final m = Float32List(20);
    m[0] = scale;
    m[4] = bias;
    m[6] = scale;
    m[9] = bias;
    m[12] = scale;
    m[14] = bias;
    m[18] = 1;
    return m;
  }

  /// Saturation interpolates between luminance and original. [value] in [-1, 1].
  static Float32List saturation(double value) {
    final s = 1.0 + value;
    const lr = 0.2126;
    const lg = 0.7152;
    const lb = 0.0722;
    final inv = 1.0 - s;
    final m = Float32List(20);
    m[0] = lr * inv + s;
    m[1] = lg * inv;
    m[2] = lb * inv;
    m[5] = lr * inv;
    m[6] = lg * inv + s;
    m[7] = lb * inv;
    m[10] = lr * inv;
    m[11] = lg * inv;
    m[12] = lb * inv + s;
    m[18] = 1;
    return m;
  }

  /// Hue rotation in degrees around the luminance axis.
  static Float32List hue(double degrees) {
    final r = degrees * math.pi / 180.0;
    final c = math.cos(r);
    final s = math.sin(r);
    final m = Float32List(20);
    m[0] = 0.213 + c * 0.787 - s * 0.213;
    m[1] = 0.715 - c * 0.715 - s * 0.715;
    m[2] = 0.072 - c * 0.072 + s * 0.928;
    m[5] = 0.213 - c * 0.213 + s * 0.143;
    m[6] = 0.715 + c * 0.285 + s * 0.140;
    m[7] = 0.072 - c * 0.072 - s * 0.283;
    m[10] = 0.213 - c * 0.213 - s * 0.787;
    m[11] = 0.715 - c * 0.715 + s * 0.715;
    m[12] = 0.072 + c * 0.928 + s * 0.072;
    m[18] = 1;
    return m;
  }

  /// Exposure in stops. [stops] in roughly [-4, 4].
  static Float32List exposure(double stops) {
    final k = math.pow(2, stops).toDouble();
    final m = Float32List(20);
    m[0] = k;
    m[6] = k;
    m[12] = k;
    m[18] = 1;
    return m;
  }

  /// Channel mixer. Each of [r], [g], [b] should be length 3 (R, G, B
  /// source contributions). Empty lists are treated as identity.
  static Float32List channelMixer(
    List<double> r,
    List<double> g,
    List<double> b,
  ) {
    final m = identity();
    if (r.length == 3) {
      m[0] = r[0];
      m[1] = r[1];
      m[2] = r[2];
    }
    if (g.length == 3) {
      m[5] = g[0];
      m[6] = g[1];
      m[7] = g[2];
    }
    if (b.length == 3) {
      m[10] = b[0];
      m[11] = b[1];
      m[12] = b[2];
    }
    return m;
  }

  /// Multiply two 5x4 matrices: `out = a * b`. The bias column accumulates
  /// from both operands.
  static Float32List multiply(Float32List a, Float32List b) {
    final result = Float32List(20);
    for (int row = 0; row < 4; row++) {
      for (int col = 0; col < 5; col++) {
        double sum = 0;
        for (int k = 0; k < 4; k++) {
          sum += a[row * 5 + k] * b[k * 5 + col];
        }
        if (col == 4) sum += a[row * 5 + 4];
        result[row * 5 + col] = sum;
      }
    }
    return result;
  }

  /// Convert a composed matrix to a Flutter [ColorFilter.matrix].
  static ColorFilter toColorFilter(Float32List m) {
    return ColorFilter.matrix(m.toList(growable: false));
  }
}
