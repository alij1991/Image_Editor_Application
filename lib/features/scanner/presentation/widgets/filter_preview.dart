import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../domain/models/scan_models.dart';

/// VIII.4 — pure helper that maps a [ScanFilter] to a [ColorFilter]
/// approximation of what the filter does at preview scale. The real
/// pipeline (perspective warp, OpenCV multi-scale Retinex, adaptive
/// threshold) is too expensive to run per chip per source change, so
/// these matrices capture the *visual character* of each filter:
///
/// - **auto**: light contrast / saturation bump — close to identity.
/// - **color**: stronger contrast + saturation pop.
/// - **grayscale**: luminance-weighted desaturate.
/// - **bw**: high-contrast luminance threshold approximation.
/// - **magicColor**: warm-bias illumination lift.
///
/// Returned matrices are 20-element row-major 5×4 form suitable for
/// `ColorFilter.matrix(...)`.
class FilterPreview {
  const FilterPreview._();

  static ColorFilter colorFilterFor(ScanFilter filter) {
    return ColorFilter.matrix(matrixFor(filter).toList());
  }

  /// Public so tests can compare matrices without going through Flutter.
  static Float32List matrixFor(ScanFilter filter) {
    switch (filter) {
      case ScanFilter.auto:
        // Light contrast 1.08 + saturation 1.03 (matches _applyFilter's
        // auto branch).
        return _saturate(1.03, baseContrast: 1.08);
      case ScanFilter.color:
        return _saturate(1.15, baseContrast: 1.15);
      case ScanFilter.grayscale:
        // Luminance-weighted desaturate.
        return _saturate(0.0, baseContrast: 1.10);
      case ScanFilter.bw:
        // Aggressive contrast + desaturate to approximate the
        // adaptive-threshold output. Real B&W is binary; the approx
        // here just collapses midtones.
        return _saturate(0.0, baseContrast: 1.6);
      case ScanFilter.magicColor:
        // Warm-bias matrix that mirrors the MSR retinex output: lift
        // the page to white via a +brightness, slight warmth boost on
        // R, slight cool dampen on B.
        return Float32List.fromList(<double>[
          1.10, 0, 0, 0, 8,
          0, 1.05, 0, 0, 4,
          0, 0, 0.95, 0, -4,
          0, 0, 0, 1, 0,
        ]);
    }
  }

  /// Saturation matrix with optional pre-multiplied contrast.
  /// Mirrors `MatrixComposer.saturation(s)` * contrast wiring used by
  /// the editor's own preview path.
  static Float32List _saturate(double s, {double baseContrast = 1.0}) {
    // Luminance coefficients (BT.709). Same shape as the editor's
    // saturation matrix.
    const lr = 0.2126, lg = 0.7152, lb = 0.0722;
    final invS = 1 - s;
    final c = baseContrast;
    // Translation needed to keep mid-grey at 0.5 when contrast is
    // applied: t = (1 - c) * 128.
    final t = (1 - c) * 128.0;
    return Float32List.fromList(<double>[
      c * (lr * invS + s), c * (lg * invS), c * (lb * invS), 0, t,
      c * (lr * invS), c * (lg * invS + s), c * (lb * invS), 0, t,
      c * (lr * invS), c * (lg * invS), c * (lb * invS + s), 0, t,
      0, 0, 0, 1, 0,
    ]);
  }
}
