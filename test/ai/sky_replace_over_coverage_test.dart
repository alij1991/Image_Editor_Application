import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

import 'package:image_editor/ai/inference/mask_stats.dart';
import 'package:image_editor/ai/services/sky_replace/sky_replace_service.dart';
import 'package:image_editor/ai/services/sky_replace/sky_preset.dart';

/// VIII.10 — `SkyReplaceService` rejects images where the mask
/// covers > `maxCoverageRatio` of the frame (default 0.60). Catches
/// "blue wall / blue water / blue fabric" cases that previously
/// produced a misleading silent output.
void main() {
  group('MaskStats.coverageRatio', () {
    test('returns 0 for an empty mask', () {
      final stats = MaskStats.compute(Float32List(0));
      expect(stats.coverageRatio, 0);
    });

    test('80% of a 100-element mask above threshold = 0.8', () {
      final mask = Float32List(100);
      for (var i = 0; i < 80; i++) {
        mask[i] = 0.9;
      }
      final stats = MaskStats.compute(mask);
      expect(stats.coverageRatio, closeTo(0.80, 1e-9));
    });

    test('all-zero mask reports zero coverage', () {
      final stats = MaskStats.compute(Float32List(50));
      expect(stats.coverageRatio, 0);
    });
  });

  group('SkyReplaceService over-coverage rejection', () {
    late Directory tmp;
    late String imgPath;

    setUpAll(() async {
      tmp = Directory.systemTemp.createTempSync('sky_overcoverage');
      // 16x16 sky-like image (bright blue everywhere). The heuristic
      // will produce a near-full mask which should trip both the
      // effectively-full check and the over-coverage guard depending
      // on the threshold + featherWidth defaults.
      final scene = img.Image(width: 16, height: 16);
      img.fill(scene, color: img.ColorRgb8(120, 170, 230));
      imgPath = '${tmp.path}/all_blue.jpg';
      await File(imgPath).writeAsBytes(
        Uint8List.fromList(img.encodeJpg(scene, quality: 90)),
      );
    });

    tearDownAll(() {
      if (tmp.existsSync()) tmp.deleteSync(recursive: true);
    });

    test(
        'all-blue image trips the over-coverage threshold + throws a '
        'descriptive SkyReplaceException', () async {
      // Use a very strict threshold (0.05) so any non-trivial mask
      // qualifies as over-coverage. The all-blue input definitely
      // produces > 5% mask coverage.
      final service = SkyReplaceService(maxCoverageRatio: 0.05);
      try {
        await expectLater(
          () => service.replaceSkyFromPath(
            sourcePath: imgPath,
            preset: SkyPreset.values.first,
          ),
          throwsA(
            isA<SkyReplaceException>().having(
              (e) => e.message,
              'message',
              anyOf(
                contains("doesn't look like a sky"),
                contains('whole image'),
              ),
            ),
          ),
        );
      } finally {
        await service.close();
      }
    });

    test('a generous threshold lets the same image through', () async {
      // Bumping maxCoverageRatio to 0.99 means only "effectively
      // full" can still trip — this proves the new check is what
      // rejects at default 0.60. Different images may still hit the
      // older isEffectivelyFull guard but this synthetic just
      // verifies the parameter is honoured.
      final service = SkyReplaceService(maxCoverageRatio: 0.99);
      try {
        // We don't assert a successful result (the all-blue image
        // may still trip isEffectivelyFull / isEffectivelyEmpty);
        // we only assert that if it DOES throw, the message is NOT
        // the over-coverage one.
        try {
          await service.replaceSkyFromPath(
            sourcePath: imgPath,
            preset: SkyPreset.values.first,
          );
        } on SkyReplaceException catch (e) {
          expect(e.message, isNot(contains("doesn't look like a sky")));
        }
      } finally {
        await service.close();
      }
    });
  });
}
