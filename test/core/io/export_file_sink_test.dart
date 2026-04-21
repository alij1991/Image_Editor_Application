import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'package:image_editor/core/io/export_file_sink.dart';

/// Behaviour tests for the Phase IV.1 `writeExportBytes` /
/// `writeExportString` consolidation.
///
/// Before Phase IV.1 five exporters each carried their own
/// `_saveBytes` + `_timestampName` pair. This file pins the contract
/// the single helper honours — subdir creation, title sanitisation,
/// timestamp fallback, extension handling, prefix customisation,
/// overwrite semantics, and the test-only root override.
void main() {
  late Directory tmp;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('export_file_sink_test');
    debugExportRootOverride = tmp;
  });

  tearDown(() {
    debugExportRootOverride = null;
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  group('writeExportBytes', () {
    test('writes to <root>/<subdir>/<title><ext>', () async {
      final file = await writeExportBytes(
        bytes: Uint8List.fromList([1, 2, 3, 4]),
        subdir: 'scan_exports',
        extension: '.pdf',
        title: 'My Document',
      );
      expect(file.path, p.join(tmp.path, 'scan_exports', 'My Document.pdf'));
      expect(await file.exists(), isTrue);
      expect(await file.readAsBytes(), [1, 2, 3, 4]);
    });

    test('creates the subdirectory if missing', () async {
      final subdir = Directory(p.join(tmp.path, 'scan_exports'));
      expect(subdir.existsSync(), isFalse,
          reason: 'sanity: helper should create this');
      await writeExportBytes(
        bytes: Uint8List.fromList([0]),
        subdir: 'scan_exports',
        extension: '.pdf',
        title: 'doc',
      );
      expect(subdir.existsSync(), isTrue);
    });

    test('works when subdirectory already exists', () async {
      Directory(p.join(tmp.path, 'scan_exports')).createSync(recursive: true);
      final file = await writeExportBytes(
        bytes: Uint8List.fromList([0]),
        subdir: 'scan_exports',
        extension: '.pdf',
        title: 'doc',
      );
      expect(await file.exists(), isTrue);
    });

    test('creates nested subdirectories', () async {
      final file = await writeExportBytes(
        bytes: Uint8List.fromList([0]),
        subdir: 'deep/nested/exports',
        extension: '.pdf',
        title: 'doc',
      );
      expect(file.path,
          p.join(tmp.path, 'deep/nested/exports', 'doc.pdf'));
      expect(await file.exists(), isTrue);
    });

    test('sanitises filesystem-unsafe characters in title', () async {
      final file = await writeExportBytes(
        bytes: Uint8List.fromList([0]),
        subdir: 'out',
        extension: '.pdf',
        // Mix of allowed chars and ones the regex replaces with _.
        title: r'My <Receipt>: 2024/08/03 "final" *draft*',
      );
      expect(p.basename(file.path),
          'My _Receipt__ 2024_08_03 _final_ _draft_.pdf');
    });

    test('trims leading/trailing whitespace in title', () async {
      final file = await writeExportBytes(
        bytes: Uint8List.fromList([0]),
        subdir: 'out',
        extension: '.pdf',
        title: '   spaced out  ',
      );
      expect(p.basename(file.path), 'spaced out.pdf');
    });

    test('falls back to timestamp when title is null', () async {
      final file = await writeExportBytes(
        bytes: Uint8List.fromList([0]),
        subdir: 'out',
        extension: '.pdf',
      );
      // Default prefix is 'Scan'.
      expect(p.basename(file.path),
          matches(RegExp(r'^Scan_\d{8}_\d{6}\.pdf$')));
    });

    test('falls back to timestamp when title is empty', () async {
      final file = await writeExportBytes(
        bytes: Uint8List.fromList([0]),
        subdir: 'out',
        extension: '.pdf',
        title: '',
      );
      expect(p.basename(file.path),
          matches(RegExp(r'^Scan_\d{8}_\d{6}\.pdf$')));
    });

    test('falls back to timestamp when title is whitespace-only', () async {
      final file = await writeExportBytes(
        bytes: Uint8List.fromList([0]),
        subdir: 'out',
        extension: '.pdf',
        title: '   \t  ',
      );
      expect(p.basename(file.path),
          matches(RegExp(r'^Scan_\d{8}_\d{6}\.pdf$')));
    });

    test('honours custom timestampPrefix', () async {
      final file = await writeExportBytes(
        bytes: Uint8List.fromList([0]),
        subdir: 'out',
        extension: '.png',
        timestampPrefix: 'Collage',
      );
      expect(p.basename(file.path),
          matches(RegExp(r'^Collage_\d{8}_\d{6}\.png$')));
    });

    test('timestamp format is YYYYMMDD_HHmmss with zero padding', () async {
      final file = await writeExportBytes(
        bytes: Uint8List.fromList([0]),
        subdir: 'out',
        extension: '.pdf',
      );
      // Regex above already verifies zero-pad. Double-check length:
      // "Scan_" (5) + 8 + "_" (1) + 6 + ".pdf" (4) = 24
      expect(p.basename(file.path).length, 24);
    });

    test('overwrites existing file with same title', () async {
      final first = await writeExportBytes(
        bytes: Uint8List.fromList([1, 1, 1]),
        subdir: 'out',
        extension: '.pdf',
        title: 'doc',
      );
      final second = await writeExportBytes(
        bytes: Uint8List.fromList([2, 2, 2]),
        subdir: 'out',
        extension: '.pdf',
        title: 'doc',
      );
      // Same target path.
      expect(second.path, first.path);
      // Bytes reflect the SECOND write.
      expect(await second.readAsBytes(), [2, 2, 2]);
    });

    test('extension is appended verbatim (caller owns the leading dot)',
        () async {
      // If callers forget the leading dot the helper won't add one —
      // pin that behaviour so the exporter migration check (all 5
      // exporters pass '.pdf', '.docx', etc.) catches a regression.
      final file = await writeExportBytes(
        bytes: Uint8List.fromList([0]),
        subdir: 'out',
        extension: 'pdf', // no leading dot
        title: 'doc',
      );
      expect(p.basename(file.path), 'docpdf');
    });
  });

  group('writeExportString', () {
    test('writes UTF-8 text to the target file', () async {
      final file = await writeExportString(
        content: 'hello\nworld',
        subdir: 'out',
        extension: '.txt',
        title: 'doc',
      );
      expect(await file.readAsString(), 'hello\nworld');
    });

    test('handles non-ASCII content via UTF-8 encoding', () async {
      const content = 'Ñoño © 你好 🍕';
      final file = await writeExportString(
        content: content,
        subdir: 'out',
        extension: '.txt',
        title: 'intl',
      );
      expect(await file.readAsString(), content);
      // Confirm the file is actually UTF-8 on disk.
      final bytes = await file.readAsBytes();
      expect(utf8.decode(bytes), content);
    });

    test('shares subdir / title / extension logic with writeExportBytes',
        () async {
      final file = await writeExportString(
        content: 'x',
        subdir: 'deep/nest',
        extension: '.txt',
        title: r'weird/title?',
      );
      expect(file.path,
          p.join(tmp.path, 'deep/nest', 'weird_title_.txt'));
      expect(await file.readAsString(), 'x');
    });
  });

  group('debugExportRootOverride', () {
    test('directs writes to the override dir instead of app docs', () async {
      // Already set in setUp. Sanity: file lands under tmp, not the
      // platform's real documents dir.
      final file = await writeExportBytes(
        bytes: Uint8List.fromList([0]),
        subdir: 'sink',
        extension: '.bin',
        title: 'doc',
      );
      expect(file.path.startsWith(tmp.path), isTrue);
    });

    test('restoring to null is safe even without prior writes', () async {
      debugExportRootOverride = null;
      // No throw, no state to clean up.
      expect(debugExportRootOverride, isNull);
    });
  });
}
