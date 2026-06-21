import 'dart:isolate';
import 'dart:typed_data';

import 'package:archive/archive.dart';

/// XVI.126 (D4) — off-UI-isolate ZIP deflate.
///
/// The `archive` package's `ZipEncoder` is pure-Dart and CPU-heavy: a
/// multi-page scan bundle (or a .docx, which is a ZIP of OOXML parts)
/// blocks the UI thread ~0.5–1.5 s if deflated inline. This runs it on a
/// short-lived worker isolate via [Isolate.run]. Entries are plain
/// name + bytes, which copy across the isolate boundary cleanly.

/// One member of a ZIP: its archive path [name] and raw [bytes].
typedef ZipEntry = ({String name, Uint8List bytes});

/// Build a ZIP from [entries] on a worker isolate. Returns the encoded
/// archive bytes.
Future<Uint8List> zipFilesInIsolate(List<ZipEntry> entries) {
  return Isolate.run(() => _zip(entries));
}

/// Top-level so it can run inside [Isolate.run] (no captured `this`).
Uint8List _zip(List<ZipEntry> entries) {
  final archive = Archive();
  for (final e in entries) {
    archive.addFile(ArchiveFile(e.name, e.bytes.length, e.bytes));
  }
  final encoded = ZipEncoder().encode(archive);
  return encoded is Uint8List ? encoded : Uint8List.fromList(encoded);
}
