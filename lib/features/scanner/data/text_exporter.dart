import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

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
    final file = await _saveString(buffer.toString(), session.title);
    _log.i('exported', {
      'pages': written,
      'path': file.path,
      'ms': sw.elapsedMilliseconds,
    });
    return file;
  }

  Future<File> _saveString(String content, String? title) async {
    final dir = await getApplicationDocumentsDirectory();
    final exportsDir = Directory(p.join(dir.path, 'scan_exports'));
    if (!exportsDir.existsSync()) exportsDir.createSync(recursive: true);
    final name =
        (title == null || title.trim().isEmpty) ? _timestampName() : title.trim();
    final safe = name.replaceAll(RegExp(r'[^A-Za-z0-9._ -]'), '_');
    final path = p.join(exportsDir.path, '$safe.txt');
    final file = File(path);
    await file.writeAsString(content);
    return file;
  }

  String _timestampName() {
    final now = DateTime.now();
    two(int n) => n.toString().padLeft(2, '0');
    return 'Scan_${now.year}${two(now.month)}${two(now.day)}_'
        '${two(now.hour)}${two(now.minute)}${two(now.second)}';
  }
}
