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
///
/// ## Phase VI.2 — scratch buffers
///
/// The public API has two shapes:
///
/// - [compose] returns a freshly allocated [Float32List]. Safe to retain
///   across later `compose` calls. Use this from cold paths (preset
///   thumbnail cache, one-shot exporters).
/// - [composeInto] writes into a caller-provided 20-element buffer and
///   returns it. Zero allocations across the call — the composer reuses
///   static scratch buffers for the per-op matrix and the multiply
///   accumulator. Use this from the editor slider hot path where the
///   same buffer can be passed every frame.
///
/// Both variants share the same inner loop; the static intermediate
/// buffers (`_workScratch`, `_tmpScratch`) were allocated once per
/// isolate and are safe to share because Dart's single-threaded model
/// prevents concurrent access and `composeInto` never yields.
class MatrixComposer {
  const MatrixComposer();

  /// Per-op matrix scratch — populated by [_fillMatrixFor] for each
  /// enabled matrix-composable op. Static because `const` instances
  /// can't carry fields and Dart's single isolate means no contention.
  static final Float32List _workScratch = Float32List(20);

  /// Multiply output scratch — [_multiplyInto] writes `a * b` here
  /// before the result is copied back into the accumulator. Separate
  /// from the accumulator to avoid read-after-write aliasing during
  /// the matmul inner loop.
  static final Float32List _tmpScratch = Float32List(20);

  /// Identity 5x4 matrix as a freshly allocated [Float32List].
  /// Prefer [_fillIdentity] for in-place writes to avoid allocating.
  static Float32List identity() {
    final m = Float32List(20);
    m[0] = 1;
    m[6] = 1;
    m[12] = 1;
    m[18] = 1;
    return m;
  }

  /// Compose every matrix-composable op in [pipeline] into a single matrix.
  /// Disabled ops are skipped. Returns a freshly allocated 20-element
  /// [Float32List]; safe to retain.
  Float32List compose(EditPipeline pipeline) {
    final out = Float32List(20);
    composeInto(pipeline, out);
    return out;
  }

  /// Compose directly into [out]. Returns [out] for fluent chaining.
  ///
  /// Zero allocations: the per-op matrix is written into a static scratch
  /// buffer and the multiply result is accumulated through a second
  /// scratch, then copied back into [out]. Pass the same [out] every
  /// frame (e.g. from `PassBuildContext.matrixScratch`) for a truly
  /// allocation-free hot path.
  ///
  /// [out] must be length 20. Caller must not retain [out] past the
  /// next [composeInto] call with the same buffer — the contents are
  /// overwritten, not copied.
  Float32List composeInto(EditPipeline pipeline, Float32List out) {
    assert(out.length == 20, 'composeInto requires a 20-element buffer');
    _fillIdentity(out);
    for (final op in pipeline.operations) {
      if (!op.enabled) continue;
      if (!op.isMatrixComposable) continue;
      if (!_fillMatrixFor(op, _workScratch)) continue;
      // out <- _workScratch * out, routed through _tmpScratch because
      // _multiplyInto's output buffer must not alias either operand.
      _multiplyInto(_workScratch, out, _tmpScratch);
      out.setAll(0, _tmpScratch);
    }
    return out;
  }

  /// Write [op]'s 5x4 matrix into [out]. Returns true, or false (leaving
  /// [out] untouched) if [op] has no matrix representation. Used by
  /// [composeInto] so the per-op intermediate goes into a scratch buffer
  /// instead of a fresh allocation.
  bool _fillMatrixFor(EditOperation op, Float32List out) {
    switch (op.type) {
      case EditOpType.brightness:
        _fillBrightness(op.doubleParam('value'), out);
        return true;
      case EditOpType.contrast:
        _fillContrast(op.doubleParam('value'), out);
        return true;
      case EditOpType.saturation:
        _fillSaturation(op.doubleParam('value'), out);
        return true;
      case EditOpType.hue:
        _fillHue(op.doubleParam('value'), out);
        return true;
      case EditOpType.exposure:
        _fillExposure(op.doubleParam('value'), out);
        return true;
      case EditOpType.channelMixer:
        _fillChannelMixer(
          op.doubleListParam('red'),
          op.doubleListParam('green'),
          op.doubleListParam('blue'),
          out,
        );
        return true;
    }
    return false;
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
    final m = Float32List(20);
    _fillContrast(value, m);
    return m;
  }

  /// Saturation interpolates between luminance and original. [value] in [-1, 1].
  static Float32List saturation(double value) {
    final m = Float32List(20);
    _fillSaturation(value, m);
    return m;
  }

  /// Hue rotation in degrees around the luminance axis.
  static Float32List hue(double degrees) {
    final m = Float32List(20);
    _fillHue(degrees, m);
    return m;
  }

  /// Exposure in stops. [stops] in roughly [-4, 4].
  static Float32List exposure(double stops) {
    final m = Float32List(20);
    _fillExposure(stops, m);
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
    _fillChannelMixer(r, g, b, m);
    return m;
  }

  /// Multiply two 5x4 matrices: `out = a * b`. The bias column accumulates
  /// from both operands.
  static Float32List multiply(Float32List a, Float32List b) {
    final result = Float32List(20);
    _multiplyInto(a, b, result);
    return result;
  }

  /// Convert a composed matrix to a Flutter [ColorFilter.matrix].
  static ColorFilter toColorFilter(Float32List m) {
    return ColorFilter.matrix(m.toList(growable: false));
  }

  // --- Private in-place variants used by [composeInto]. Each of these
  //     overwrites [m] completely so callers don't need to pre-zero. ---

  static void _fillIdentity(Float32List m) {
    for (int i = 0; i < 20; i++) {
      m[i] = 0;
    }
    m[0] = 1;
    m[6] = 1;
    m[12] = 1;
    m[18] = 1;
  }

  static void _fillBrightness(double value, Float32List m) {
    _fillIdentity(m);
    m[4] = value;
    m[9] = value;
    m[14] = value;
  }

  static void _fillContrast(double value, Float32List m) {
    final scale = 1.0 + value;
    final bias = 0.5 * (1.0 - scale);
    for (int i = 0; i < 20; i++) {
      m[i] = 0;
    }
    m[0] = scale;
    m[4] = bias;
    m[6] = scale;
    m[9] = bias;
    m[12] = scale;
    m[14] = bias;
    m[18] = 1;
  }

  static void _fillSaturation(double value, Float32List m) {
    final s = 1.0 + value;
    const lr = 0.2126;
    const lg = 0.7152;
    const lb = 0.0722;
    final inv = 1.0 - s;
    for (int i = 0; i < 20; i++) {
      m[i] = 0;
    }
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
  }

  static void _fillHue(double degrees, Float32List m) {
    final r = degrees * math.pi / 180.0;
    final c = math.cos(r);
    final s = math.sin(r);
    for (int i = 0; i < 20; i++) {
      m[i] = 0;
    }
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
  }

  static void _fillExposure(double stops, Float32List m) {
    final k = math.pow(2, stops).toDouble();
    for (int i = 0; i < 20; i++) {
      m[i] = 0;
    }
    m[0] = k;
    m[6] = k;
    m[12] = k;
    m[18] = 1;
  }

  static void _fillChannelMixer(
    List<double> r,
    List<double> g,
    List<double> b,
    Float32List m,
  ) {
    _fillIdentity(m);
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
  }

  /// Multiply 5x4 matrices: `out = a * b`. The bias column accumulates
  /// from both operands.
  ///
  /// **Aliasing rule**: [out] must not share storage with [a] or [b].
  /// The matmul inner loop reads every element of [a] and [b] before
  /// each write to [out]; an aliased output would corrupt mid-loop.
  /// [composeInto] routes around this by multiplying into [_tmpScratch]
  /// and copying back.
  static void _multiplyInto(Float32List a, Float32List b, Float32List out) {
    assert(
      !identical(out, a) && !identical(out, b),
      '_multiplyInto output must not alias either operand',
    );
    for (int row = 0; row < 4; row++) {
      for (int col = 0; col < 5; col++) {
        double sum = 0;
        for (int k = 0; k < 4; k++) {
          sum += a[row * 5 + k] * b[k * 5 + col];
        }
        if (col == 4) sum += a[row * 5 + 4];
        out[row * 5 + col] = sum;
      }
    }
  }
}
