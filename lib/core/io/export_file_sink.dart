import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// Consistent export-file sink for every exporter the app ships.
///
/// Before Phase IV.1 every exporter carried its own `_saveBytes` +
/// `_timestampName` pair (5 copies: `PdfExporter`, `DocxExporter`,
/// `JpegZipExporter`, `TextExporter`, `CollageExporter`). They agreed
/// on every detail except the timestamp prefix and the file extension,
/// so `prefix` + `extension` + `subdir` + `title` are the only knobs
/// this module exposes.
///
/// Responsibilities:
///   - create the subdirectory under the app documents dir if missing
///   - pick a filename: user-provided `title` (trimmed) if non-empty,
///     otherwise `<prefix>_YYYYMMDD_HHmmss`
///   - sanitise the chosen name (strip characters that break on iOS /
///     Android filesystems)
///   - append the file extension and write bytes (or UTF-8 text)
///
/// Two entry points: [writeExportBytes] and [writeExportString].
/// Exporters pick based on their output format — PDF, DOCX, ZIP, PNG
/// go through bytes; text exports use the string path.
///
/// Unlike `atomic_file.dart`, export writes are **not** atomic — they
/// land in a stable-named file whose freshness is implicit in the
/// user-facing export action. A kill mid-write leaves a corrupted file
/// the user can simply re-export over. Making export-writes atomic
/// would trade simplicity for a failure mode users can already
/// recover from trivially.
Future<File> writeExportBytes({
  required Uint8List bytes,
  required String subdir,
  required String extension, // include the leading dot: '.pdf' / '.zip'
  String? title,
  String timestampPrefix = 'Scan',
}) async {
  final file = await _prepareExportFile(
    subdir: subdir,
    extension: extension,
    title: title,
    timestampPrefix: timestampPrefix,
  );
  await file.writeAsBytes(bytes);
  return file;
}

/// UTF-8 text counterpart to [writeExportBytes]. Used by the plain-text
/// scan exporter (OCR dump).
Future<File> writeExportString({
  required String content,
  required String subdir,
  required String extension,
  String? title,
  String timestampPrefix = 'Scan',
}) async {
  final file = await _prepareExportFile(
    subdir: subdir,
    extension: extension,
    title: title,
    timestampPrefix: timestampPrefix,
  );
  await file.writeAsString(content);
  return file;
}

/// Test-only hook that replaces the docs directory with a caller-
/// provided `Directory`. Production code leaves this `null`. Tests
/// using a `Directory.systemTemp.createTempSync()` root MUST restore
/// the hook to `null` in `tearDown` — it's global state.
@visibleForTesting
Directory? debugExportRootOverride;

Future<File> _prepareExportFile({
  required String subdir,
  required String extension,
  required String? title,
  required String timestampPrefix,
}) async {
  final root =
      debugExportRootOverride ?? await getApplicationDocumentsDirectory();
  final exportsDir = Directory(p.join(root.path, subdir));
  if (!exportsDir.existsSync()) exportsDir.createSync(recursive: true);
  final base = (title == null || title.trim().isEmpty)
      ? _timestampName(timestampPrefix)
      : title.trim();
  final safe = _sanitize(base);
  return File(p.join(exportsDir.path, '$safe$extension'));
}

String _sanitize(String name) =>
    name.replaceAll(RegExp(r'[^A-Za-z0-9._ -]'), '_');

String _timestampName(String prefix) {
  final now = DateTime.now();
  String two(int n) => n.toString().padLeft(2, '0');
  return '${prefix}_${now.year}${two(now.month)}${two(now.day)}_'
      '${two(now.hour)}${two(now.minute)}${two(now.second)}';
}
