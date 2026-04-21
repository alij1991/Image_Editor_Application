import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:image_editor/core/io/atomic_file.dart';

/// Behaviour tests for `atomicWriteString` / `atomicWriteBytes`.
///
/// The key atomicity guarantee — "readers see either the old content or
/// the new content, never a truncated mix" — is verified by injecting a
/// throw via [debugHookBeforeRename] AFTER the tmp write but BEFORE the
/// rename, then asserting the target file still holds its prior
/// content (or doesn't exist when it never had any).
void main() {
  late Directory tmp;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('atomic_file_test');
    // Clear any residual hook from a test that forgot tearDown.
    debugHookBeforeRename = null;
  });

  tearDown(() {
    debugHookBeforeRename = null;
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  File path(String name) => File('${tmp.path}/$name');

  group('atomicWriteString', () {
    test('writes to a new target file', () async {
      final f = path('fresh.json');
      await atomicWriteString(f, '{"ok": true}');
      expect(await f.exists(), true);
      expect(await f.readAsString(), '{"ok": true}');
    });

    test('overwrites an existing target file', () async {
      final f = path('existing.json');
      await f.writeAsString('{"old": true}');
      await atomicWriteString(f, '{"new": true}');
      expect(await f.readAsString(), '{"new": true}');
    });

    test('creates missing parent directories', () async {
      final f = File('${tmp.path}/nested/dir/fresh.json');
      await atomicWriteString(f, 'hi');
      expect(await f.exists(), true);
      expect(await f.readAsString(), 'hi');
    });

    test('leaves no .tmp sibling after a successful write', () async {
      final f = path('clean.json');
      await atomicWriteString(f, '{}');
      final tmpSibling = File('${f.path}.tmp');
      expect(await tmpSibling.exists(), false);
    });

    test('preserves existing target when writer throws mid-flow', () async {
      final f = path('preserved.json');
      await f.writeAsString('{"keep": "me"}');

      // Simulate a kill between flush and rename.
      debugHookBeforeRename = () async {
        throw const FileSystemException('simulated crash');
      };

      await expectLater(
        () => atomicWriteString(f, '{"lost": "write"}'),
        throwsA(isA<FileSystemException>()),
      );

      // The target file still holds its pre-write content.
      expect(await f.readAsString(), '{"keep": "me"}');
    });

    test('cleans up the tmp sibling when writer throws', () async {
      final f = path('cleanup.json');
      debugHookBeforeRename = () async {
        throw StateError('simulated');
      };

      await expectLater(
        () => atomicWriteString(f, 'new'),
        throwsA(isA<StateError>()),
      );

      final tmpSibling = File('${f.path}.tmp');
      expect(await tmpSibling.exists(), false,
          reason: 'tmp file must be removed when the write aborts');
    });

    test('leaves target absent when the first save crashes', () async {
      final f = path('neverWritten.json');
      debugHookBeforeRename = () async {
        throw StateError('first save crashed');
      };
      await expectLater(
        () => atomicWriteString(f, 'doomed'),
        throwsA(isA<StateError>()),
      );
      expect(await f.exists(), false,
          reason: 'the target must not materialise from a failed write');
    });

    test('overwrites a stale .tmp left from a prior crash', () async {
      final f = path('survivor.json');
      // Simulate a prior crashed save: old tmp hanging around.
      await File('${f.path}.tmp').writeAsString('stale leftover bytes');

      await atomicWriteString(f, '{"fresh": "run"}');

      expect(await f.readAsString(), '{"fresh": "run"}');
      // The tmp shouldn't remain after the successful rename.
      expect(await File('${f.path}.tmp').exists(), false);
    });

    test('round-trips Unicode and multi-line payloads', () async {
      final f = path('unicode.json');
      const payload = '{"greeting": "héllo wörld 🌍", "line2": "new\\nline"}';
      await atomicWriteString(f, payload);
      expect(await f.readAsString(), payload);
    });
  });

  group('atomicWriteBytes', () {
    test('writes raw bytes to a new target', () async {
      final f = path('raw.bin');
      await atomicWriteBytes(f, Uint8List.fromList([0xde, 0xad, 0xbe, 0xef]));
      expect(await f.readAsBytes(), [0xde, 0xad, 0xbe, 0xef]);
    });

    test('overwrites an existing target', () async {
      final f = path('raw.bin');
      await f.writeAsBytes([1, 2, 3]);
      await atomicWriteBytes(f, Uint8List.fromList([9, 9, 9]));
      expect(await f.readAsBytes(), [9, 9, 9]);
    });

    test('preserves existing bytes when writer throws mid-flow', () async {
      final f = path('raw.bin');
      await f.writeAsBytes([0x01, 0x02, 0x03]);

      debugHookBeforeRename = () async {
        throw const FileSystemException('simulated crash');
      };

      await expectLater(
        () => atomicWriteBytes(f, Uint8List.fromList([0xff, 0xff, 0xff])),
        throwsA(isA<FileSystemException>()),
      );

      expect(await f.readAsBytes(), [0x01, 0x02, 0x03]);
    });

    test('cleans up tmp sibling on failure', () async {
      final f = path('raw.bin');
      debugHookBeforeRename = () async => throw StateError('boom');
      await expectLater(
        () => atomicWriteBytes(f, Uint8List.fromList([0])),
        throwsA(isA<StateError>()),
      );
      expect(await File('${f.path}.tmp').exists(), false);
    });
  });

  group('debugHookBeforeRename contract', () {
    test('is null by default', () {
      expect(debugHookBeforeRename, isNull);
    });

    test('resets after a hook-throwing test (via tearDown)', () async {
      // Two back-to-back hook fires; the second test would be
      // contaminated if the first didn't reset. tearDown enforces this
      // but we exercise one explicit success-after-failure here to
      // pin the behaviour.
      debugHookBeforeRename = () async => throw StateError('first');
      final f = path('first.json');
      await expectLater(
        () => atomicWriteString(f, 'a'),
        throwsA(isA<StateError>()),
      );

      // Now reset + do a clean write: it must succeed.
      debugHookBeforeRename = null;
      await atomicWriteString(f, 'b');
      expect(await f.readAsString(), 'b');
    });
  });
}
