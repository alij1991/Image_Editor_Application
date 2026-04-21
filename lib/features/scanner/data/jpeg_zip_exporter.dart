import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';

import '../../../core/io/export_file_sink.dart';
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
    final file = await writeExportBytes(
      bytes: Uint8List.fromList(encoded),
      subdir: 'scan_exports',
      extension: '.zip',
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

}
