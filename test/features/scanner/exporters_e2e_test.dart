import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

import 'package:image_editor/features/scanner/data/jpeg_zip_exporter.dart';
import 'package:image_editor/features/scanner/data/pdf_exporter.dart';
import 'package:image_editor/features/scanner/data/text_exporter.dart';
import 'package:image_editor/features/scanner/domain/models/scan_models.dart';

/// IX.C.1 — end-to-end exporter tests for PDF, Text, and JPEG ZIP.
/// DOCX is already covered by `docx_exporter_ocr_toggle_test.dart`
/// (VIII.18). The PDF encryption-absence contract is covered by
/// `pdf_exporter_password_honesty_test.dart` (Phase I.8) — this file
/// complements with multi-page + OCR + bytes-on-disk coverage.
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
  late String img1;
  late String img2;

  setUpAll(() async {
    tmp = Directory.systemTemp.createTempSync('exporters_e2e');
    PathProviderPlatform.instance = _TmpPathProvider(tmp.path);
    Future<String> synth(String name, int r, int g, int b) async {
      final scene = img.Image(width: 200, height: 260);
      img.fill(scene, color: img.ColorRgb8(r, g, b));
      final path = '${tmp.path}/$name';
      await File(path).writeAsBytes(
        Uint8List.fromList(img.encodeJpg(scene, quality: 80)),
      );
      return path;
    }

    img1 = await synth('p1.jpg', 230, 220, 210);
    img2 = await synth('p2.jpg', 40, 30, 20);
  });

  tearDownAll(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  ScanSession twoPageSession({
    String title = 'e2e-test',
    String? ocrText1,
    String? ocrText2,
  }) =>
      ScanSession(
        title: title,
        pages: [
          ScanPage(
            id: 'p1',
            rawImagePath: img1,
            processedImagePath: img1,
            ocr: ocrText1 == null
                ? null
                : OcrResult(fullText: ocrText1, blocks: const []),
          ),
          ScanPage(
            id: 'p2',
            rawImagePath: img2,
            processedImagePath: img2,
            ocr: ocrText2 == null
                ? null
                : OcrResult(fullText: ocrText2, blocks: const []),
          ),
        ],
      );

  group('PdfExporter', () {
    test('produces a valid multi-page PDF starting with %PDF header',
        () async {
      final file = await const PdfExporter().export(
        twoPageSession(),
        options: const ExportOptions(),
      );
      expect(file.existsSync(), isTrue);
      final bytes = await file.readAsBytes();
      expect(String.fromCharCodes(bytes.take(5)), '%PDF-');
      expect(bytes.length, greaterThan(1000),
          reason: 'two-page PDF with embedded JPEGs must be non-trivial');
    });

    test('includes OCR text blocks when ocr is attached + includeOcr=true',
        () async {
      final file = await const PdfExporter().export(
        twoPageSession(ocrText1: 'Hello World', ocrText2: 'Goodbye'),
        options: const ExportOptions(),
      );
      final bytes = await file.readAsBytes();
      expect(String.fromCharCodes(bytes.take(5)), '%PDF-');
      // Text is rasterised / encoded in a PDF text object, so bytes
      // should be materially larger than the no-OCR case. We pin that
      // the output path handled OCR without crashing; actual
      // searchability is verified by pdfbox-style tooling, not here.
      expect(bytes.length, greaterThan(2000));
    });

    test('accepts includeOcr=false without crashing + still emits valid PDF',
        () async {
      // The `pdf` package's stream optimiser collapses invisible-text
      // widgets to the same byte output as the image-only case for
      // small bodies, so we can't pin "bytes differ" reliably. Instead
      // we verify the toggle path runs end-to-end: a session with
      // blocks, includeOcr=false must still produce a valid PDF (no
      // crash in the overlay-skip branch) with the %PDF- header. The
      // DOCX equivalent (`docx_exporter_ocr_toggle_test.dart`) covers
      // the "text body absent" contract with a format that's easier
      // to inspect.
      final sessionWithBlocks = ScanSession(
        title: 'no-ocr-test',
        pages: [
          ScanPage(
            id: 'p1',
            rawImagePath: img1,
            processedImagePath: img1,
            ocr: const OcrResult(
              fullText: 'alpha beta gamma',
              blocks: [
                OcrBlock(
                  text: 'alpha',
                  left: 10,
                  top: 10,
                  width: 60,
                  height: 20,
                ),
                OcrBlock(
                  text: 'beta',
                  left: 10,
                  top: 40,
                  width: 60,
                  height: 20,
                ),
              ],
            ),
          ),
        ],
      );
      final file = await const PdfExporter().export(
        sessionWithBlocks,
        options: const ExportOptions(includeOcr: false),
      );
      final bytes = await file.readAsBytes();
      expect(String.fromCharCodes(bytes.take(5)), '%PDF-');
      expect(bytes.length, greaterThan(500));
    });
  });

  group('TextExporter', () {
    test('writes page separators + OCR text', () async {
      final file = await const TextExporter().export(
        twoPageSession(ocrText1: 'Alpha', ocrText2: 'Bravo'),
      );
      final text = await file.readAsString();
      expect(text, contains('--- Page 1 ---'));
      expect(text, contains('Alpha'));
      expect(text, contains('--- Page 2 ---'));
      expect(text, contains('Bravo'));
    });

    test('skips pages without OCR', () async {
      final file = await const TextExporter().export(
        twoPageSession(ocrText1: 'Alpha'), // no ocr on page 2
      );
      final text = await file.readAsString();
      expect(text, contains('--- Page 1 ---'));
      expect(text, contains('Alpha'));
      // Page 2 header should not appear — only pages with OCR text.
      expect(text, isNot(contains('--- Page 2 ---')));
    });

    test('degrades gracefully when no page has OCR', () async {
      final file = await const TextExporter().export(twoPageSession());
      final text = await file.readAsString();
      expect(text, contains('No text was recognised'));
    });

    test('utf-8 content round-trips', () async {
      final file = await const TextExporter().export(
        twoPageSession(ocrText1: 'Café résumé naïve — \u00e9'),
      );
      final raw = await file.readAsBytes();
      final decoded = utf8.decode(raw);
      expect(decoded, contains('Café'));
      expect(decoded, contains('résumé'));
    });
  });

  group('JpegZipExporter', () {
    test('bundles every processed page as a sequentially-named JPEG',
        () async {
      final file = await const JpegZipExporter().export(twoPageSession());
      expect(file.existsSync(), isTrue);
      final bytes = await file.readAsBytes();
      final archive = ZipDecoder().decodeBytes(bytes);
      expect(archive.files.length, 2);
      expect(archive.files[0].name, 'page_001.jpg');
      expect(archive.files[1].name, 'page_002.jpg');
    });

    test('archive contents decode as valid JPEGs', () async {
      final file = await const JpegZipExporter().export(twoPageSession());
      final archive = ZipDecoder().decodeBytes(
        await file.readAsBytes(),
      );
      for (final entry in archive.files) {
        final decoded = img.decodeImage(
          Uint8List.fromList(entry.content as List<int>),
        );
        expect(decoded, isNotNull,
            reason: 'archive entry ${entry.name} must decode as JPEG');
        expect(decoded!.width, 200);
        expect(decoded.height, 260);
      }
    });

    test('empty session throws StateError (defensive)', () async {
      expect(
        () => const JpegZipExporter().export(
          ScanSession(title: 'empty', pages: const []),
        ),
        throwsA(isA<StateError>()),
      );
    });

    test('pad-left naming handles 10+ pages correctly', () async {
      final pages = [
        for (var i = 0; i < 12; i++)
          ScanPage(
            id: 'p${i + 1}',
            rawImagePath: i.isEven ? img1 : img2,
            processedImagePath: i.isEven ? img1 : img2,
          ),
      ];
      final file = await const JpegZipExporter().export(
        ScanSession(title: 'twelve', pages: pages),
      );
      final archive = ZipDecoder().decodeBytes(await file.readAsBytes());
      expect(archive.files.length, 12);
      // 001, 002, ..., 012 — zero-padded so filesystem sort works.
      expect(archive.files.first.name, 'page_001.jpg');
      expect(archive.files.last.name, 'page_012.jpg');
    });
  });
}
