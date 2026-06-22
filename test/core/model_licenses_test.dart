import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:image_editor/core/licenses/model_licenses.dart';

/// XVI.130 (A6) — the in-app Licenses screen must attribute the shipped
/// ML model weights (Dart packages are auto-collected; raw model assets
/// are not). LicenseRegistry is process-global, so reset around the test
/// to assert exactly our entries.
void main() {
  setUp(LicenseRegistry.reset);
  tearDown(LicenseRegistry.reset);

  Future<List<LicenseEntry>> collect() => LicenseRegistry.licenses.toList();

  test('registers attributions for the shipped clean model set', () async {
    registerModelLicenses();
    final entries = await collect();
    final packages = entries.expand((e) => e.packages).toSet();

    // A representative model from each license group is attributed.
    expect(packages, containsAll(<String>[
      'MediaPipe Selfie Segmentation (model)', // Apache
      'LaMa big-lama inpainting (model)', // Apache
      'MODNet portrait matting (model)', // Apache (clean; PPM-100 NC is eval-only)
      'MI-GAN inpainting (model)', // MIT
      'NAFNet deblur (model)', // MIT
      'DnCNN denoise — deepinv (model)', // BSD-3
      'Real-ESRGAN super-resolution (model)', // BSD-3
      'MobileViT v2 (model)', // Apple ml-cvnets
    ]));
  });

  test('each group carries the correct license body + attribution', () async {
    registerModelLicenses();
    final entries = await collect();
    String textFor(String pkg) => entries
        .firstWhere((e) => e.packages.contains(pkg))
        .paragraphs
        .map((p) => p.text)
        .join('\n');

    final apache = textFor('MODNet portrait matting (model)');
    expect(apache, contains('Apache License'));
    expect(apache, contains('github.com/advimman/lama')); // LaMa attribution

    final mit = textFor('MI-GAN inpainting (model)');
    expect(mit, contains('MIT License'));
    expect(mit, contains('Picsart')); // MI-GAN copyright

    final bsd = textFor('DnCNN denoise — deepinv (model)');
    expect(bsd, contains('BSD 3-Clause'));
    expect(bsd, contains('deepinv')); // corrected provenance (not KAIR/MIT)

    final apple = textFor('MobileViT v2 (model)');
    expect(apple, contains('Apple')); // Apple ml-cvnets notice retained
  });

  test('dropped non-commercial models are NOT attributed', () async {
    registerModelLicenses();
    final entries = await collect();
    final blob =
        entries.expand((e) => e.packages).join('\n').toLowerCase();
    // SegFormer (NVIDIA-NC) + Harmonizer (CC-BY-NC-SA) were dropped, not
    // attributed — listing them would imply they ship.
    expect(blob, isNot(contains('segformer')));
    expect(blob, isNot(contains('harmonizer')));
  });
}
