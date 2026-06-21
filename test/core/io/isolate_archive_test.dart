import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:image_editor/core/io/isolate_archive.dart';

/// XVI.126 (D4) — the off-UI-isolate ZIP helper. Runs real Isolate.run
/// work and round-trips through ZipDecoder so a regression in the entry
/// marshalling or deflate wiring is caught.
void main() {
  test('zipFilesInIsolate round-trips entry names + bytes', () async {
    final a = Uint8List.fromList(List<int>.generate(256, (i) => i));
    final b = Uint8List.fromList('hello world'.codeUnits);
    final zip = await zipFilesInIsolate([
      (name: 'a.bin', bytes: a),
      (name: 'sub/b.txt', bytes: b),
    ]);

    // Valid ZIP local-file-header signature "PK\x03\x04".
    expect(zip.sublist(0, 4), [0x50, 0x4B, 0x03, 0x04]);

    final decoded = ZipDecoder().decodeBytes(zip);
    final names = decoded.files.map((f) => f.name).toList()..sort();
    expect(names, ['a.bin', 'sub/b.txt']);
    final aOut = decoded.files.firstWhere((f) => f.name == 'a.bin');
    expect(aOut.content, equals(a));
    final bOut = decoded.files.firstWhere((f) => f.name == 'sub/b.txt');
    expect(bOut.content, equals(b));
  });

  test('empty entry list produces a valid (empty) archive', () async {
    final zip = await zipFilesInIsolate(const []);
    final decoded = ZipDecoder().decodeBytes(zip);
    expect(decoded.files, isEmpty);
  });
}
