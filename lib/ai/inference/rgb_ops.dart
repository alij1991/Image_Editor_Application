import 'dart:math' as math;
import 'dart:typed_data';

/// Pure-Dart per-pixel RGB adjustments used by Phase 9e beauty
/// services. Each helper returns a fresh RGBA8 buffer and never
/// mutates the caller's input. Alpha is always preserved — these
/// operations are meant to be composited onto the original via a
/// landmark mask later, so touching alpha would break the blend.
class RgbOps {
  const RgbOps._();

  /// Multiply every RGB channel by [factor] and clamp to `[0, 255]`.
  ///
  /// - `factor < 1.0` darkens; `factor > 1.0` brightens.
  /// - Alpha is copied through.
  ///
  /// Kept simple on purpose — the mask composite step controls
  /// *where* the brightness lands, so we don't need fancy highlight
  /// rolloff inside the kernel.
  static Uint8List brightenRgb({
    required Uint8List source,
    required int width,
    required int height,
    required double factor,
  }) {
    if (width <= 0 || height <= 0) {
      throw ArgumentError('width/height must be > 0');
    }
    if (source.length != width * height * 4) {
      throw ArgumentError(
        'source length ${source.length} != ${width * height * 4}',
      );
    }
    if (factor < 0) {
      throw ArgumentError('factor must be >= 0');
    }

    final out = Uint8List(source.length);
    for (int i = 0; i < source.length; i += 4) {
      final r = source[i] * factor;
      final g = source[i + 1] * factor;
      final b = source[i + 2] * factor;
      out[i] = r < 0 ? 0 : (r > 255 ? 255 : r.round());
      out[i + 1] = g < 0 ? 0 : (g > 255 ? 255 : g.round());
      out[i + 2] = b < 0 ? 0 : (b > 255 ? 255 : b.round());
      out[i + 3] = source[i + 3];
    }
    return out;
  }

  /// Desaturate + brighten — the "whitening" kernel for teeth.
  ///
  /// For every pixel, compute the Rec. 709 luminance `L` and push
  /// each channel toward `L` by [desaturate] (so `0` = no change,
  /// `1` = fully greyscale), then multiply by [brightness] and
  /// clamp. The combined effect is a gentle yellow-cast reducer +
  /// highlight bump, which is what the common teeth-whiten recipe
  /// does in LAB space without the overhead.
  ///
  /// Alpha is copied through. This op is applied uniformly inside a
  /// mouth-shape mask — the mask, not the kernel, is responsible
  /// for keeping it off the lips and skin.
  static Uint8List whitenRgb({
    required Uint8List source,
    required int width,
    required int height,
    required double desaturate,
    required double brightness,
  }) {
    if (width <= 0 || height <= 0) {
      throw ArgumentError('width/height must be > 0');
    }
    if (source.length != width * height * 4) {
      throw ArgumentError(
        'source length ${source.length} != ${width * height * 4}',
      );
    }
    if (desaturate < 0 || desaturate > 1) {
      throw ArgumentError('desaturate must be in [0, 1]');
    }
    if (brightness < 0) {
      throw ArgumentError('brightness must be >= 0');
    }

    final keep = 1 - desaturate;
    final out = Uint8List(source.length);
    for (int i = 0; i < source.length; i += 4) {
      final r = source[i].toDouble();
      final g = source[i + 1].toDouble();
      final b = source[i + 2].toDouble();
      // Rec. 709 luminance (same weights as the ITU-R standard).
      final lum = 0.2126 * r + 0.7152 * g + 0.0722 * b;
      final nr = (lum + (r - lum) * keep) * brightness;
      final ng = (lum + (g - lum) * keep) * brightness;
      final nb = (lum + (b - lum) * keep) * brightness;
      out[i] = nr < 0 ? 0 : (nr > 255 ? 255 : nr.round());
      out[i + 1] = ng < 0 ? 0 : (ng > 255 ? 255 : ng.round());
      out[i + 2] = nb < 0 ? 0 : (nb > 255 ? 255 : nb.round());
      out[i + 3] = source[i + 3];
    }
    return out;
  }

  /// LAB-space teeth whitening — the recipe pro photo editors use.
  ///
  /// Converts sRGB → linear → CIE XYZ → CIE L*a*b*, then:
  ///   - pulls `b*` toward 0 by [yellowRemoval] (removes the yellow
  ///     cast that makes teeth look stained),
  ///   - lifts `L*` by [luminanceBoost] (brightens the enamel),
  ///   - leaves `a*` largely alone (teeth are green-magenta neutral).
  ///
  /// The previous RGB-space `whitenRgb` (desaturate + multiply) shifts
  /// teeth toward grey because pushing all three channels toward
  /// luminance kills the subtle blue-white that healthy enamel has.
  /// Working in LAB keeps the perceptual white-point honest so the
  /// result reads as "whiter" instead of "greyer".
  ///
  /// Alpha is copied through. All RGB/LAB math is D65-white-point
  /// sRGB, matching the display gamut.
  ///
  /// - [yellowRemoval]: fraction of the current `b*` to null out.
  ///   `0` = no change, `1` = fully neutral `b*`. `0.6` is a safe
  ///   default that still keeps the enamel looking warm-ish.
  /// - [luminanceBoost]: additive push to `L*` in the 0..100 scale.
  ///   `5` is a noticeable lift, `12` starts looking bleached.
  static Uint8List whitenLab({
    required Uint8List source,
    required int width,
    required int height,
    double yellowRemoval = 0.6,
    double luminanceBoost = 6.0,
  }) {
    if (width <= 0 || height <= 0) {
      throw ArgumentError('width/height must be > 0');
    }
    if (source.length != width * height * 4) {
      throw ArgumentError(
        'source length ${source.length} != ${width * height * 4}',
      );
    }
    if (yellowRemoval < 0 || yellowRemoval > 1) {
      throw ArgumentError('yellowRemoval must be in [0, 1]');
    }
    if (luminanceBoost < 0) {
      throw ArgumentError('luminanceBoost must be >= 0');
    }

    final out = Uint8List(source.length);
    for (int i = 0; i < source.length; i += 4) {
      final r = source[i] / 255.0;
      final g = source[i + 1] / 255.0;
      final b = source[i + 2] / 255.0;

      // sRGB → linear.
      final lr = _srgbToLinear(r);
      final lg = _srgbToLinear(g);
      final lb = _srgbToLinear(b);

      // linear RGB → XYZ (D65, sRGB matrix).
      final x = lr * 0.4124564 + lg * 0.3575761 + lb * 0.1804375;
      final y = lr * 0.2126729 + lg * 0.7151522 + lb * 0.0721750;
      final z = lr * 0.0193339 + lg * 0.1191920 + lb * 0.9503041;

      // XYZ → L*a*b* (D65 reference white).
      final fx = _labF(x / 0.95047);
      final fy = _labF(y / 1.00000);
      final fz = _labF(z / 1.08883);
      double L = 116 * fy - 16;
      double A = 500 * (fx - fy);
      double B = 200 * (fy - fz);

      // Apply whitening: null out yellow (positive b*), lift L*.
      // Negative b* (blue cast) is left alone — teeth rarely come in
      // pre-bluetinted and nulling would push them grey.
      if (B > 0) B *= (1.0 - yellowRemoval);
      L = (L + luminanceBoost).clamp(0.0, 100.0);

      // L*a*b* → XYZ (inverse path).
      final fyNew = (L + 16) / 116;
      final fxNew = A / 500 + fyNew;
      final fzNew = fyNew - B / 200;
      final xNew = 0.95047 * _labFInv(fxNew);
      final yNew = 1.00000 * _labFInv(fyNew);
      final zNew = 1.08883 * _labFInv(fzNew);

      // XYZ → linear RGB.
      final lrNew = xNew * 3.2404542 - yNew * 1.5371385 - zNew * 0.4985314;
      final lgNew = -xNew * 0.9692660 + yNew * 1.8760108 + zNew * 0.0415560;
      final lbNew = xNew * 0.0556434 - yNew * 0.2040259 + zNew * 1.0572252;

      final rNew = _linearToSrgb(lrNew.clamp(0.0, 1.0)) * 255;
      final gNew = _linearToSrgb(lgNew.clamp(0.0, 1.0)) * 255;
      final bNew = _linearToSrgb(lbNew.clamp(0.0, 1.0)) * 255;

      out[i] = rNew.round().clamp(0, 255);
      out[i + 1] = gNew.round().clamp(0, 255);
      out[i + 2] = bNew.round().clamp(0, 255);
      out[i + 3] = source[i + 3];
    }
    return out;
  }

  /// Phase XV.2: recolour masked pixels by shifting their `a*` and
  /// `b*` Lab channels toward the target colour while preserving
  /// their original `L*` (luminance + shading).
  ///
  /// This is how pro-quality hair / clothing recolouring works —
  /// shading is preserved because `L*` isn't touched. A flat-colour
  /// fill (e.g. paint a red rectangle) would look like a sticker
  /// glued on top; an a*b* shift keeps the subject's own lighting
  /// intact.
  ///
  /// - [source]: RGBA8 buffer of size [width] × [height].
  /// - [mask]: per-pixel float weight in `[0, 1]`. Zero = unchanged,
  ///   1 = fully recoloured, values between blend proportionally.
  ///   Length MUST equal `width × height`.
  /// - [targetR], [targetG], [targetB]: target sRGB colour in
  ///   `0..255`. Its `a*` / `b*` values get projected onto the
  ///   subject's existing `L*`.
  /// - [strength]: overall blend amount in `[0, 1]`. 1.0 = fully
  ///   replace the a*/b* of masked pixels with the target; 0.5 =
  ///   halfway (a softer tint); 0 = no-op. Clamped at the call site
  ///   for defence-in-depth.
  ///
  /// Alpha is copied through. Unmasked pixels are byte-identical to
  /// the source.
  static Uint8List shiftLabAbForMaskedPixels({
    required Uint8List source,
    required int width,
    required int height,
    required Float32List mask,
    required int targetR,
    required int targetG,
    required int targetB,
    double strength = 1.0,
  }) {
    if (width <= 0 || height <= 0) {
      throw ArgumentError('width/height must be > 0');
    }
    if (source.length != width * height * 4) {
      throw ArgumentError(
        'source length ${source.length} != ${width * height * 4}',
      );
    }
    if (mask.length != width * height) {
      throw ArgumentError(
        'mask length ${mask.length} != ${width * height}',
      );
    }
    final s = strength.clamp(0.0, 1.0);

    // 1. Compute the target colour's (a*, b*) once. L* is thrown
    //    away — we keep each source pixel's own L*.
    final (targetA, targetB2) = _sRgbToAb(
      targetR / 255.0,
      targetG / 255.0,
      targetB / 255.0,
    );

    final out = Uint8List(source.length);
    for (int p = 0; p < mask.length; p++) {
      final i = p * 4;
      final m = mask[p];
      if (m <= 0 || s <= 0) {
        out[i] = source[i];
        out[i + 1] = source[i + 1];
        out[i + 2] = source[i + 2];
        out[i + 3] = source[i + 3];
        continue;
      }

      final r = source[i] / 255.0;
      final g = source[i + 1] / 255.0;
      final b = source[i + 2] / 255.0;
      final (L, srcA, srcB) = _sRgbToLab(r, g, b);

      // Blend towards the target a*/b* by `strength * mask`.
      final t = (s * m).clamp(0.0, 1.0);
      final newA = srcA + (targetA - srcA) * t;
      final newB = srcB + (targetB2 - srcB) * t;

      final (rn, gn, bn) = _labToSrgb(L, newA, newB);
      out[i] = (rn * 255).round().clamp(0, 255);
      out[i + 1] = (gn * 255).round().clamp(0, 255);
      out[i + 2] = (bn * 255).round().clamp(0, 255);
      out[i + 3] = source[i + 3];
    }
    return out;
  }

  /// sRGB `[0, 1]` → CIE `(L*, a*, b*)`.
  static (double, double, double) _sRgbToLab(double r, double g, double b) {
    final lr = _srgbToLinear(r);
    final lg = _srgbToLinear(g);
    final lb = _srgbToLinear(b);
    final x = lr * 0.4124564 + lg * 0.3575761 + lb * 0.1804375;
    final y = lr * 0.2126729 + lg * 0.7151522 + lb * 0.0721750;
    final z = lr * 0.0193339 + lg * 0.1191920 + lb * 0.9503041;
    final fx = _labF(x / 0.95047);
    final fy = _labF(y / 1.00000);
    final fz = _labF(z / 1.08883);
    final L = 116 * fy - 16;
    final A = 500 * (fx - fy);
    final B = 200 * (fy - fz);
    return (L, A, B);
  }

  /// sRGB `[0, 1]` → `(a*, b*)` only. Used for the target-colour
  /// projection where L* is intentionally discarded.
  static (double, double) _sRgbToAb(double r, double g, double b) {
    final (_, A, B) = _sRgbToLab(r, g, b);
    return (A, B);
  }

  /// CIE `(L*, a*, b*)` → sRGB `[0, 1]` (gamut-clipped).
  static (double, double, double) _labToSrgb(double L, double A, double B) {
    final fy = (L + 16) / 116;
    final fx = A / 500 + fy;
    final fz = fy - B / 200;
    final x = 0.95047 * _labFInv(fx);
    final y = 1.00000 * _labFInv(fy);
    final z = 1.08883 * _labFInv(fz);
    final lr = x * 3.2404542 - y * 1.5371385 - z * 0.4985314;
    final lg = -x * 0.9692660 + y * 1.8760108 + z * 0.0415560;
    final lb = x * 0.0556434 - y * 0.2040259 + z * 1.0572252;
    return (
      _linearToSrgb(lr.clamp(0.0, 1.0)),
      _linearToSrgb(lg.clamp(0.0, 1.0)),
      _linearToSrgb(lb.clamp(0.0, 1.0)),
    );
  }

  // --- sRGB <-> linear (IEC 61966-2-1 piecewise curve) -----------
  static double _srgbToLinear(double c) {
    return c <= 0.04045 ? c / 12.92 : math.pow((c + 0.055) / 1.055, 2.4).toDouble();
  }

  static double _linearToSrgb(double c) {
    return c <= 0.0031308
        ? c * 12.92
        : 1.055 * math.pow(c, 1.0 / 2.4).toDouble() - 0.055;
  }

  // --- CIE L*a*b* companding (f / f⁻¹) ----------------------------
  static double _labF(double t) {
    const delta = 6.0 / 29.0;
    return t > delta * delta * delta
        ? math.pow(t, 1.0 / 3.0).toDouble()
        : t / (3 * delta * delta) + 4.0 / 29.0;
  }

  static double _labFInv(double t) {
    const delta = 6.0 / 29.0;
    return t > delta ? t * t * t : 3 * delta * delta * (t - 4.0 / 29.0);
  }
}
