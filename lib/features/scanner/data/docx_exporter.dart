import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:image/image.dart' as img;

import '../../../core/io/export_file_sink.dart';
import '../../../core/logging/app_logger.dart';
import '../domain/models/scan_models.dart';

final _log = AppLogger('DocxExporter');

/// Builds a minimal but Word-compatible `.docx` from a [ScanSession].
///
/// A `.docx` file is a ZIP whose members are OOXML parts. We hand-roll
/// only the parts Word actually requires to open the file:
///
///   [Content_Types].xml
///   _rels/.rels
///   word/document.xml
///   word/_rels/document.xml.rels
///   word/media/image{N}.jpeg     (one per page)
///
/// For each page we emit an inline image (scaled to page width) and,
/// when an [OcrResult] is attached, the recognised text as visible
/// paragraphs. That keeps the user's document searchable AND editable
/// in Word without requiring a true PDF-style hidden text layer.
class DocxExporter {
  const DocxExporter();

  Future<File> export(
    ScanSession session, {
    required ExportOptions options,
  }) async {
    final sw = Stopwatch()..start();
    if (session.pages.isEmpty) {
      throw StateError('DocxExporter: session has no pages');
    }

    final archive = Archive();

    // Content types ---------------------------------------------------------
    archive.addFile(_text(
      '[Content_Types].xml',
      '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
          '<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">'
          '<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>'
          '<Default Extension="xml" ContentType="application/xml"/>'
          '<Default Extension="jpeg" ContentType="image/jpeg"/>'
          '<Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>'
          '</Types>',
    ));

    // Root rels -------------------------------------------------------------
    archive.addFile(_text(
      '_rels/.rels',
      '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
          '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
          '<Relationship Id="rId1" '
          'Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" '
          'Target="word/document.xml"/>'
          '</Relationships>',
    ));

    // Images + per-page relationships + document body ----------------------
    final body = StringBuffer();
    final rels = StringBuffer()
      ..write(
          '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
          '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">');

    for (var i = 0; i < session.pages.length; i++) {
      final page = session.pages[i];
      final imagePath = page.processedImagePath ?? page.rawImagePath;
      final bytes = await File(imagePath).readAsBytes();

      // If the source isn't JPEG, recompress so the docx stays small.
      final jpegBytes = _ensureJpeg(bytes, options.jpegQuality);

      final imgIndex = i + 1;
      final rId = 'rImg$imgIndex';
      archive.addFile(
        ArchiveFile('word/media/image$imgIndex.jpeg', jpegBytes.length, jpegBytes),
      );
      rels.write(
        '<Relationship Id="$rId" '
        'Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/image" '
        'Target="media/image$imgIndex.jpeg"/>',
      );

      // Embed image at ~6 inches wide (9 cm ≈ 3429000 EMU). Word shrinks
      // it proportionally to fit the page.
      final decoded = img.decodeImage(jpegBytes);
      final w = decoded?.width ?? 1200;
      final h = decoded?.height ?? 1600;
      const maxWidthEmu = 5486400; // 6 inches in EMU
      final aspect = w == 0 ? 1.0 : h / w;
      final widthEmu = maxWidthEmu;
      final heightEmu = (maxWidthEmu * aspect).round();

      body.write(_paragraphForImage(rId, widthEmu, heightEmu, imgIndex));

      if (options.includeOcr && page.ocr != null && page.ocr!.fullText.trim().isNotEmpty) {
        for (final line in page.ocr!.fullText.split('\n')) {
          if (line.trim().isEmpty) continue;
          body.write(_paragraph(line));
        }
      }

      // Page break between pages (not after the last).
      if (i < session.pages.length - 1) {
        body.write(_pageBreakParagraph());
      }
    }

    rels.write('</Relationships>');
    archive.addFile(_text('word/_rels/document.xml.rels', rels.toString()));

    final title = _escape(session.title ?? 'Scanned document');
    archive.addFile(_text(
      'word/document.xml',
      '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
          '<w:document '
          'xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main" '
          'xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" '
          'xmlns:wp="http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing" '
          'xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" '
          'xmlns:pic="http://schemas.openxmlformats.org/drawingml/2006/picture">'
          '<w:body>'
          '${_paragraph(title, bold: true, size: 28)}'
          '$body'
          '<w:sectPr><w:pgSz w:w="12240" w:h="15840"/>'
          '<w:pgMar w:top="1440" w:right="1440" w:bottom="1440" w:left="1440"/></w:sectPr>'
          '</w:body></w:document>',
    ));

    final encoded = ZipEncoder().encode(archive);
    final file = await writeExportBytes(
      bytes: Uint8List.fromList(encoded),
      subdir: 'scan_exports',
      extension: '.docx',
      title: session.title,
    );
    _log.i('exported', {
      'pages': session.pages.length,
      'bytes': encoded.length,
      'path': file.path,
      'ms': sw.elapsedMilliseconds,
    });
    return file;
  }

  ArchiveFile _text(String name, String content) {
    final bytes = utf8.encode(content);
    return ArchiveFile(name, bytes.length, bytes);
  }

  /// If the input isn't already a JPEG, re-encode it so Word's Default
  /// `jpeg` content-type is accurate.
  Uint8List _ensureJpeg(Uint8List bytes, int quality) {
    // Cheap JPEG SOI marker check.
    if (bytes.length >= 2 && bytes[0] == 0xFF && bytes[1] == 0xD8) {
      return bytes;
    }
    final decoded = img.decodeImage(bytes);
    if (decoded == null) return bytes;
    return Uint8List.fromList(img.encodeJpg(decoded, quality: quality));
  }

  String _paragraph(String text, {bool bold = false, int size = 22}) {
    final b = bold ? '<w:b/>' : '';
    return '<w:p><w:pPr><w:rPr>$b<w:sz w:val="$size"/></w:rPr></w:pPr>'
        '<w:r><w:rPr>$b<w:sz w:val="$size"/></w:rPr>'
        '<w:t xml:space="preserve">${_escape(text)}</w:t></w:r></w:p>';
  }

  String _pageBreakParagraph() =>
      '<w:p><w:r><w:br w:type="page"/></w:r></w:p>';

  String _paragraphForImage(String rId, int widthEmu, int heightEmu, int seq) {
    return '<w:p><w:r><w:drawing>'
        '<wp:inline distT="0" distB="0" distL="0" distR="0">'
        '<wp:extent cx="$widthEmu" cy="$heightEmu"/>'
        '<wp:effectExtent l="0" t="0" r="0" b="0"/>'
        '<wp:docPr id="$seq" name="Picture $seq"/>'
        '<wp:cNvGraphicFramePr><a:graphicFrameLocks noChangeAspect="1" '
        'xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main"/></wp:cNvGraphicFramePr>'
        '<a:graphic><a:graphicData '
        'uri="http://schemas.openxmlformats.org/drawingml/2006/picture">'
        '<pic:pic>'
        '<pic:nvPicPr>'
        '<pic:cNvPr id="$seq" name="Picture $seq"/>'
        '<pic:cNvPicPr/>'
        '</pic:nvPicPr>'
        '<pic:blipFill><a:blip r:embed="$rId"/><a:stretch><a:fillRect/></a:stretch></pic:blipFill>'
        '<pic:spPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="$widthEmu" cy="$heightEmu"/></a:xfrm>'
        '<a:prstGeom prst="rect"><a:avLst/></a:prstGeom></pic:spPr>'
        '</pic:pic>'
        '</a:graphicData></a:graphic>'
        '</wp:inline></w:drawing></w:r></w:p>';
  }

  String _escape(String s) => s
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;')
      .replaceAll('"', '&quot;')
      .replaceAll("'", '&apos;');

}
