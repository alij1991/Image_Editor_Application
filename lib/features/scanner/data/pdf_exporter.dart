import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import '../../../core/io/export_file_sink.dart';
import '../../../core/logging/app_logger.dart';
import '../domain/models/scan_models.dart';

final _log = AppLogger('PdfExporter');

/// Builds a PDF from a [ScanSession]. Each page is embedded as a JPEG.
/// When OCR blocks are attached to a page, they're laid down as
/// invisible text beneath the image so the PDF is searchable.
///
/// NOTE: password-protected / encrypted output is NOT supported. An
/// older version of this file accepted `ExportOptions.password` and
/// silently produced an unencrypted PDF while logging a warning — a
/// false-security bug the user never saw. That field is gone as of
/// Phase I.8 (see `scan_models.dart` for the audit trail). Adding
/// encryption requires pinning a `pdf` package version where the
/// `PdfEncryption` constructor surface is stable, wiring it in here,
/// AND adding a UI affordance. Until all three land, the option stays
/// absent so users aren't lulled into thinking their scans are
/// protected when they're not.
class PdfExporter {
  const PdfExporter();

  Future<File> export(
    ScanSession session, {
    required ExportOptions options,
  }) async {
    final sw = Stopwatch()..start();
    if (session.pages.isEmpty) {
      throw StateError('PdfExporter: session has no pages');
    }

    // Read every page image off disk (I/O) on this isolate, then build +
    // serialise the PDF on a worker isolate (XVI.126 / D4): pw.Document
    // is pure-Dart and doc.save() (deflate, compress: true) blocks the UI
    // thread ~1–3 s on a multi-page scan. Only plain bytes + OCR
    // primitives cross the boundary.
    final pages = <_PdfPage>[];
    for (final page in session.pages) {
      final imagePath = page.processedImagePath ?? page.rawImagePath;
      final bytes = await File(imagePath).readAsBytes();
      final boxes = <_PdfOcrBox>[];
      if (options.includeOcr && page.ocr != null) {
        for (final b in page.ocr!.blocks) {
          boxes.add(_PdfOcrBox(
            text: b.text,
            left: b.left.toDouble(),
            top: b.top.toDouble(),
            height: b.height.toDouble(),
          ));
        }
      }
      pages.add(_PdfPage(bytes: bytes, ocr: boxes));
    }

    final payload = _PdfPayload(
      pages: pages,
      pageSize: options.pageSize,
      docTitle:
          session.title ?? 'Scan ${session.createdAt.toIso8601String()}',
    );
    final bytes = await Isolate.run(() => _buildPdfBytes(payload));

    final out = await writeExportBytes(
      bytes: bytes,
      subdir: 'scan_exports',
      extension: '.pdf',
      title: session.title,
    );
    _log.i('exported', {
      'pages': session.pages.length,
      'bytes': bytes.length,
      'path': out.path,
      'ms': sw.elapsedMilliseconds,
    });
    return out;
  }
}

/// Sendable payload for [_buildPdfBytes] — plain bytes + primitives only
/// (pw.* / dart:ui handles never cross the isolate boundary).
class _PdfPayload {
  const _PdfPayload({
    required this.pages,
    required this.pageSize,
    required this.docTitle,
  });

  final List<_PdfPage> pages;
  final PageSize pageSize;
  final String docTitle;
}

class _PdfPage {
  const _PdfPage({required this.bytes, required this.ocr});

  final Uint8List bytes;

  /// OCR boxes to lay down as invisible searchable text (empty = none),
  /// already filtered by the `includeOcr` decision on the main isolate.
  final List<_PdfOcrBox> ocr;
}

/// OCR box in source-image pixel coordinates.
class _PdfOcrBox {
  const _PdfOcrBox({
    required this.text,
    required this.left,
    required this.top,
    required this.height,
  });

  final String text;
  final double left;
  final double top;
  final double height;
}

/// Build + serialise the PDF. Runs inside [Isolate.run], so it is a
/// top-level function over sendable inputs only.
Future<Uint8List> _buildPdfBytes(_PdfPayload p) async {
  final doc = pw.Document(
    title: p.docTitle,
    author: 'Image Editor',
    pageMode: PdfPageMode.none,
    compress: true,
  );

  for (final page in p.pages) {
    final image = pw.MemoryImage(page.bytes);
    final pdfPageFormat = _pdfPageFormatFor(p.pageSize, image);
    doc.addPage(
      pw.Page(
        pageFormat: pdfPageFormat,
        margin: pw.EdgeInsets.zero,
        build: (ctx) => pw.Stack(
          children: [
            pw.Positioned.fill(
              child: pw.Image(image, fit: pw.BoxFit.contain),
            ),
            if (page.ocr.isNotEmpty)
              ..._pdfOcrOverlay(page.ocr, pdfPageFormat, image),
          ],
        ),
      ),
    );
  }

  return doc.save();
}

PdfPageFormat _pdfPageFormatFor(PageSize size, pw.MemoryImage img) {
  switch (size) {
    case PageSize.auto:
      // Fit page to image aspect so nothing gets letterboxed.
      // pdf 3.11+ types `width`/`height` as nullable; default to a
      // square aspect when the image hasn't reported dims yet.
      final imgW = img.width?.toDouble() ?? 1.0;
      final imgH = img.height?.toDouble() ?? 1.0;
      final aspect = imgH == 0 ? 1.0 : imgW / imgH;
      // Use A4 width as the reference long edge.
      const longEdge = PdfPageFormat.a4;
      if (aspect >= 1) {
        // landscape
        return PdfPageFormat(longEdge.width, longEdge.width / aspect);
      } else {
        return PdfPageFormat(longEdge.height * aspect, longEdge.height);
      }
    case PageSize.a4:
      return PdfPageFormat.a4;
    case PageSize.letter:
      return PdfPageFormat.letter;
    case PageSize.legal:
      return PdfPageFormat.legal;
  }
}

List<pw.Widget> _pdfOcrOverlay(
  List<_PdfOcrBox> boxes,
  PdfPageFormat format,
  pw.MemoryImage image,
) {
  // OCR block coords are in source-image pixels. The image is drawn
  // with BoxFit.contain inside the PDF page, so when the page aspect
  // doesn't match the image aspect, the image is letterboxed — the
  // overlay must account for the resulting offset and scale.
  final pageW = format.width;
  final pageH = format.height;
  final imgW = image.width?.toDouble() ?? 1;
  final imgH = image.height?.toDouble() ?? 1;
  final scale = math.min(pageW / imgW, pageH / imgH);
  final drawnW = imgW * scale;
  final drawnH = imgH * scale;
  final offsetX = (pageW - drawnW) / 2;
  final offsetY = (pageH - drawnH) / 2;
  return [
    for (final b in boxes)
      pw.Positioned(
        left: offsetX + b.left * scale,
        top: offsetY + b.top * scale,
        child: pw.Opacity(
          opacity: 0.0,
          child: pw.Text(
            b.text,
            style: pw.TextStyle(
              fontSize: (b.height * scale).clamp(4, 72).toDouble(),
            ),
          ),
        ),
      ),
  ];
}
