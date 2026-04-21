import 'dart:io';
import 'dart:math' as math;

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

    final doc = pw.Document(
      title: session.title ?? 'Scan ${session.createdAt.toIso8601String()}',
      author: 'Image Editor',
      pageMode: PdfPageMode.none,
      compress: true,
    );

    for (var i = 0; i < session.pages.length; i++) {
      final page = session.pages[i];
      final imagePath = page.processedImagePath ?? page.rawImagePath;
      final bytes = await File(imagePath).readAsBytes();
      final image = pw.MemoryImage(bytes);

      final pdfPageFormat = _pageFormatFor(options.pageSize, image);
      doc.addPage(
        pw.Page(
          pageFormat: pdfPageFormat,
          margin: pw.EdgeInsets.zero,
          build: (ctx) => pw.Stack(
            children: [
              pw.Positioned.fill(
                child: pw.Image(image, fit: pw.BoxFit.contain),
              ),
              if (options.includeOcr && page.ocr != null)
                ..._ocrOverlay(page.ocr!, pdfPageFormat, image),
            ],
          ),
        ),
      );
      _log.d('page added', {
        'i': i,
        'w': image.width,
        'h': image.height,
        'ocr': page.ocr != null,
      });
    }

    final out = await writeExportBytes(
      bytes: await doc.save(),
      subdir: 'scan_exports',
      extension: '.pdf',
      title: session.title,
    );
    _log.i('exported', {
      'pages': session.pages.length,
      'path': out.path,
      'ms': sw.elapsedMilliseconds,
    });
    return out;
  }

  PdfPageFormat _pageFormatFor(PageSize size, pw.MemoryImage img) {
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

  List<pw.Widget> _ocrOverlay(
    OcrResult ocr,
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
      for (final b in ocr.blocks)
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

}
