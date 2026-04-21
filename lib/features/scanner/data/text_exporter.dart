import 'dart:io';

import '../../../core/io/export_file_sink.dart';
import '../../../core/logging/app_logger.dart';
import '../domain/models/scan_models.dart';

final _log = AppLogger('TxtExporter');

/// Writes the OCR text of every page to a `.txt` file with simple
/// "--- Page N ---" separators. If a page has no OCR attached we skip
/// it; the caller should trigger OCR before exporting.
class TextExporter {
  const TextExporter();

  Future<File> export(ScanSession session) async {
    final sw = Stopwatch()..start();
    final buffer = StringBuffer();
    var written = 0;
    for (var i = 0; i < session.pages.length; i++) {
      final page = session.pages[i];
      final text = page.ocr?.fullText.trim() ?? '';
      if (text.isEmpty) continue;
      if (written > 0) buffer.writeln();
      buffer.writeln('--- Page ${i + 1} ---');
      buffer.writeln(text);
      written++;
    }
    if (written == 0) {
      _log.w('no OCR text to write', {'pages': session.pages.length});
      buffer.writeln(
        'No text was recognised on any page. '
        'Try enabling OCR before exporting.',
      );
    }
    final file = await writeExportString(
      content: buffer.toString(),
      subdir: 'scan_exports',
      extension: '.txt',
      title: session.title,
    );
    _log.i('exported', {
      'pages': written,
      'path': file.path,
      'ms': sw.elapsedMilliseconds,
    });
    return file;
  }

}
