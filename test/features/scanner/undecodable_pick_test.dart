import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

import 'package:image_editor/features/scanner/data/image_processor.dart';
import 'package:image_editor/features/scanner/domain/models/scan_models.dart';

/// IX.B.3 — gallery-pick flow handing off an undecodable file must
/// not crash the pipeline; the processor returns the page unchanged
/// (no `processedImagePath`) so the UI stays on the placeholder and
/// the user can re-pick.
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

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tmp;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('undecodable_pick');
    PathProviderPlatform.instance = _TmpPathProvider(tmp.path);
  });

  tearDown(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  Future<String> writeRandomBytes(String name, int len) async {
    final file = File('${tmp.path}/$name');
    // Not a valid JPEG / PNG / anything — the `image` package will
    // fail to decode.
    await file.writeAsBytes(Uint8List.fromList(
      List<int>.generate(len, (i) => (i * 37) & 0xff),
    ));
    return file.path;
  }

  Future<String> writeValidJpeg(String name) async {
    final scene = img.Image(width: 32, height: 32);
    img.fill(scene, color: img.ColorRgb8(200, 200, 200));
    final path = '${tmp.path}/$name';
    await File(path).writeAsBytes(
      Uint8List.fromList(img.encodeJpg(scene, quality: 80)),
    );
    return path;
  }

  test('undecodable file returns the page unchanged (no processedPath)',
      () async {
    final path = await writeRandomBytes('garbage.jpg', 256);
    final page = ScanPage(id: 'p1', rawImagePath: path);
    final processor = ScanImageProcessor();
    final result = await processor.process(page);
    expect(result.id, page.id);
    expect(result.rawImagePath, page.rawImagePath);
    expect(result.processedImagePath, isNull,
        reason: 'decode failed → page.processedImagePath must remain '
            'null so the UI stays on the placeholder');
  });

  test('empty file (zero bytes) degrades cleanly', () async {
    final path = '${tmp.path}/empty.jpg';
    await File(path).writeAsBytes(Uint8List(0));
    final page = ScanPage(id: 'p-empty', rawImagePath: path);
    final processor = ScanImageProcessor();
    final result = await processor.process(page);
    expect(result.processedImagePath, isNull);
  });

  test('preview + full process are both tolerant of decode failure',
      () async {
    final path = await writeRandomBytes('garbage2.jpg', 128);
    final page = ScanPage(id: 'p2', rawImagePath: path);
    final processor = ScanImageProcessor();
    final previewResult = await processor.processPreview(page);
    final fullResult = await processor.process(page);
    expect(previewResult.processedImagePath, isNull);
    expect(fullResult.processedImagePath, isNull);
  });

  test('control: a valid JPEG produces a processedImagePath', () async {
    final path = await writeValidJpeg('ok.jpg');
    final page = ScanPage(
      id: 'p-ok',
      rawImagePath: path,
      corners: Corners.full(),
    );
    final processor = ScanImageProcessor();
    final result = await processor.process(page);
    expect(result.processedImagePath, isNotNull,
        reason: 'sanity — decode path works when the input IS valid');
    expect(File(result.processedImagePath!).existsSync(), isTrue);
  });
}
