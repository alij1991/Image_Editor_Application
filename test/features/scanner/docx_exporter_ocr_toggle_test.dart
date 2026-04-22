import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

import 'package:image_editor/features/scanner/data/docx_exporter.dart';
import 'package:image_editor/features/scanner/domain/models/scan_models.dart';

/// VIII.18 — the "Include OCR as text" toggle on the export sheet maps
/// to `ExportOptions.includeOcr`. When off, the DOCX body must contain
/// the title paragraph + the image paragraph(s), but no OCR-derived
/// body paragraphs.
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

img.Image _fixture() {
  final scene = img.Image(width: 180, height: 240);
  img.fill(scene, color: img.ColorRgb8(240, 240, 240));
  return scene;
}

Future<String> _writeJpeg(Directory dir, String name) async {
  final f = File('${dir.path}/$name');
  await f.writeAsBytes(
    Uint8List.fromList(img.encodeJpg(_fixture(), quality: 80)),
  );
  return f.path;
}

String _extractDocumentXml(File docx) {
  final bytes = docx.readAsBytesSync();
  final archive = ZipDecoder().decodeBytes(bytes);
  final entry =
      archive.files.firstWhere((f) => f.name == 'word/document.xml');
  return utf8.decode(entry.content as List<int>);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tmp;
  late String imgPath;

  setUpAll(() async {
    tmp = Directory.systemTemp.createTempSync('docx_ocr_toggle');
    PathProviderPlatform.instance = _TmpPathProvider(tmp.path);
    imgPath = await _writeJpeg(tmp, 'page.jpg');
  });

  tearDownAll(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  ScanSession sessionWithOcr(String ocrText) => ScanSession(
        title: 'ocr-toggle',
        pages: [
          ScanPage(
            id: 'p1',
            rawImagePath: imgPath,
            ocr: ocrText.isEmpty
                ? null
                : OcrResult(fullText: ocrText, blocks: const []),
          ),
        ],
      );

  test('includeOcr=false omits OCR body paragraphs', () async {
    final file = await const DocxExporter().export(
      sessionWithOcr('Invoice total\n\$42.00\nThank you'),
      options: const ExportOptions(includeOcr: false),
    );
    final doc = _extractDocumentXml(file);

    expect(doc.contains('Invoice total'), isFalse,
        reason: 'OCR text must not appear when includeOcr=false');
    expect(doc.contains('\$42.00'), isFalse);
    expect(doc.contains('Thank you'), isFalse);
    expect(doc.contains('ocr-toggle'), isTrue,
        reason: 'title paragraph survives the toggle');
  });

  test('includeOcr=true emits each non-empty OCR line as a paragraph',
      () async {
    final file = await const DocxExporter().export(
      sessionWithOcr('Invoice total\n\$42.00\nThank you'),
      options: const ExportOptions(), // defaults includeOcr to true
    );
    final doc = _extractDocumentXml(file);

    expect(doc.contains('Invoice total'), isTrue);
    expect(doc.contains('\$42.00'), isTrue);
    expect(doc.contains('Thank you'), isTrue);
    expect(doc.contains('ocr-toggle'), isTrue);
  });

  test('includeOcr=false still emits the image paragraph', () async {
    final file = await const DocxExporter().export(
      sessionWithOcr('some text'),
      options: const ExportOptions(includeOcr: false),
    );
    final doc = _extractDocumentXml(file);
    expect(doc.contains('<w:drawing>'), isTrue,
        reason: 'the page image is always embedded regardless of OCR toggle');
  });
}
