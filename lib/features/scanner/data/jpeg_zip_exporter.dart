import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../../../core/logging/app_logger.dart';
import '../domain/models/scan_models.dart';

final _log = AppLogger('JpegZipExport');

/// Bundles every processed page JPEG into a single `.zip` named after
/// the session title. Useful when the user wants the raw scans instead
/// of (or alongside) a PDF.
class JpegZipExporter {
  const JpegZipExporter();

  Future<File> export(ScanSession session) async {
    final sw = Stopwatch()..start();
    if (session.pages.isEmpty) {
      throw StateError('JpegZipExporter: session has no pages');
    }
    final archive = Archive();
    for (var i = 0; i < session.pages.length; i++) {
      final page = session.pages[i];
      final path = page.processedImagePath ?? page.rawImagePath;
      final bytes = await File(path).readAsBytes();
      final name = 'page_${(i + 1).toString().padLeft(3, '0')}.jpg';
      archive.addFile(ArchiveFile(name, bytes.length, bytes));
    }
    final encoded = ZipEncoder().encode(archive);
    final file = await _saveBytes(Uint8List.fromList(encoded), session.title);
    _log.i('exported', {
      'pages': session.pages.length,
      'bytes': encoded.length,
      'path': file.path,
      'ms': sw.elapsedMilliseconds,
    });
    return file;
  }

  Future<File> _saveBytes(Uint8List bytes, String? title) async {
    final dir = await getApplicationDocumentsDirectory();
    final exportsDir = Directory(p.join(dir.path, 'scan_exports'));
    if (!exportsDir.existsSync()) exportsDir.createSync(recursive: true);
    final name =
        (title == null || title.trim().isEmpty) ? _timestampName() : title.trim();
    final safe = name.replaceAll(RegExp(r'[^A-Za-z0-9._ -]'), '_');
    final path = p.join(exportsDir.path, '$safe.zip');
    final file = File(path);
    await file.writeAsBytes(bytes);
    return file;
  }

  String _timestampName() {
    final now = DateTime.now();
    two(int n) => n.toString().padLeft(2, '0');
    return 'Scan_${now.year}${two(now.month)}${two(now.day)}_'
        '${two(now.hour)}${two(now.minute)}${two(now.second)}';
  }
}
