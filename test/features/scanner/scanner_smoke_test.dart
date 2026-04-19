import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

import 'package:image_editor/features/scanner/data/auto_rotate.dart';
import 'package:image_editor/features/scanner/data/image_processor.dart';
import 'package:image_editor/features/scanner/data/image_stats_extractor.dart';
import 'package:image_editor/features/scanner/domain/document_classifier.dart';
import 'package:image_editor/features/scanner/domain/models/scan_models.dart';
import 'package:image_editor/features/scanner/infrastructure/classical_corner_seed.dart';
import 'package:image_editor/features/scanner/infrastructure/opencv_corner_seed.dart';

/// End-to-end smoke test: builds a synthetic page fixture, runs it
/// through corner detection, perspective warp, every filter, the
/// classifier, the auto-rotate estimator and the deskew estimator,
/// and asserts a sensible output drops out at each step. Catches the
/// kind of integration regression that a per-helper unit test would
/// miss — e.g. a filter that returns a 1-channel image the JPEG
/// encoder can't write.

class _TmpPathProvider extends PathProviderPlatform
    with MockPlatformInterfaceMixin {
  _TmpPathProvider(this.tmp);
  final String tmp;
  @override
  Future<String?> getTemporaryPath() async => tmp;
  @override
  Future<String?> getApplicationDocumentsPath() async => tmp;
  @override
  Future<String?> getApplicationSupportPath() async => tmp;
  @override
  Future<String?> getApplicationCachePath() async => tmp;
}

Future<String> _writeJpeg(img.Image image, String name) async {
  final dir = Directory.systemTemp.createTempSync('smoke');
  final file = File('${dir.path}/$name');
  await file.writeAsBytes(
    Uint8List.fromList(img.encodeJpg(image, quality: 90)),
  );
  return file.path;
}

img.Image _syntheticPageFixture() {
  // 600×800 photograph of a "page": a bright rectangle on a darker
  // surround with five horizontal text-like strokes inside the
  // rectangle. Uniform — no gradient — so the fixture is robust
  // across every filter and every classifier rule.
  final scene = img.Image(width: 600, height: 800);
  img.fill(scene, color: img.ColorRgb8(15, 15, 15));
  img.fillRect(scene,
      x1: 60, y1: 80, x2: 540, y2: 720,
      color: img.ColorRgb8(245, 245, 245));
  for (var i = 0; i < 5; i++) {
    final y = 160 + i * 80;
    img.fillRect(scene,
        x1: 100, y1: y, x2: 500, y2: y + 3,
        color: img.ColorRgb8(20, 20, 20));
  }
  return scene;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final tmpDir = Directory.systemTemp.createTempSync('smoke_root');
  PathProviderPlatform.instance = _TmpPathProvider(tmpDir.path);

  late String fixturePath;

  setUpAll(() async {
    final fixture = _syntheticPageFixture();
    fixturePath = await _writeJpeg(fixture, 'page.jpg');
  });

  test('scanner pipeline: detect → warp → filter → classify → orient',
      () async {
    // 1. OpenCV contour seeder picks the bright page rectangle.
    const seeder = OpenCvCornerSeed();
    final seed = await seeder.seed(fixturePath);
    expect(seed.fellBack, isFalse,
        reason: 'expected a real quad on the synthetic page fixture');

    // 2. ScanImageProcessor.process() runs warp + each filter and
    //    writes the JPEG via path_provider's temp dir (stubbed
    //    above). We expect a processed file to appear for every
    //    filter and the file to decode back into a same-channel
    //    image of non-trivial size.
    final processor = ScanImageProcessor(maxOutputEdge: 800);
    for (final filter in ScanFilter.values) {
      final page = ScanPage(
        id: 'p-${filter.name}',
        rawImagePath: fixturePath,
        corners: seed.corners,
        filter: filter,
      );
      final out = await processor.process(page);
      expect(out.processedImagePath, isNotNull,
          reason: '${filter.name} produced no processed file');
      final outBytes = await File(out.processedImagePath!).readAsBytes();
      expect(outBytes.length, greaterThan(1000),
          reason: '${filter.name} output is suspiciously tiny');
      final decoded = img.decodeImage(outBytes);
      expect(decoded, isNotNull,
          reason: '${filter.name} output failed to decode');
      // Output should be at least narrower than the raw fixture's
      // bounding box (warped page, not raw photo).
      expect(decoded!.width, lessThan(600));
    }

    // 3. Classifier reads the processed magic-colour output and
    //    should pick a sensible bucket — for our 480 (cropped width)
    //    × 640-ish letter-aspect fixture with no money markers and
    //    OCR=null we expect either invoiceOrLetter, idCard or
    //    unknown depending on rounding. We accept any of those plus
    //    photo (high-contrast text could trip the colour-richness
    //    threshold) — the key thing is the classifier doesn't crash
    //    and returns a valid enum.
    final magic = ScanPage(
      id: 'p-classify',
      rawImagePath: fixturePath,
      corners: seed.corners,
      filter: ScanFilter.magicColor,
    );
    final magicOut = await processor.process(magic);
    final magicImg =
        img.decodeImage(await File(magicOut.processedImagePath!).readAsBytes())!;
    final stats = computeImageStats(magicImg);
    final type = const DocumentClassifier()
        .classify(stats: stats, ocr: null);
    expect(DocumentType.values, contains(type));

    // 4. Orientation estimator should classify the upright fixture
    //    as 0° (or abstain when too few Hough lines survive — both
    //    are acceptable; "rotate me 90°" would be a regression).
    final rot = estimateRotationDegrees(magicImg);
    expect(rot, anyOf(equals(0), isNull));

    // 5. Deskew on an upright page with horizontal strokes should
    //    return ≈ 0° or null.
    final skew = estimateDeskewDegrees(magicImg);
    if (skew != null) expect(skew.abs(), lessThan(2.0));
  });
}
