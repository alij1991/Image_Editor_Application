import 'package:flutter_test/flutter_test.dart';

import 'package:image_editor/features/scanner/infrastructure/scanner_region_prior.dart';

/// Phase XIV.3: structural tests for the region-prior contract. The
/// end-to-end integration (EfficientDet + OpenCV seeder masking)
/// relies on real models + the native OpenCV lib — covered by the
/// existing scanner_smoke_test.dart. These pin the public surface
/// so consumers of the prior don't break as the prior evolves.
void main() {
  group('ScannerRegion', () {
    test('width / height reflect right-left and bottom-top', () {
      const r = ScannerRegion(left: 0.1, top: 0.2, right: 0.7, bottom: 0.9);
      expect(r.width, closeTo(0.6, 1e-9));
      expect(r.height, closeTo(0.7, 1e-9));
    });

    test('toString renders every normalised edge with 2 decimals', () {
      const r = ScannerRegion(left: 0.12, top: 0.34, right: 0.56, bottom: 0.78);
      final s = r.toString();
      expect(s, contains('0.12'));
      expect(s, contains('0.34'));
      expect(s, contains('0.56'));
      expect(s, contains('0.78'));
    });

    test('degenerate region (zero width) still constructs — seeder '
        'filters these out at use site', () {
      const r = ScannerRegion(left: 0.5, top: 0.5, right: 0.5, bottom: 0.9);
      expect(r.width, 0);
      expect(r.height, closeTo(0.4, 1e-9));
    });
  });
}
