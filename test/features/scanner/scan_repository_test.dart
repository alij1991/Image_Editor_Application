import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:image_editor/core/io/atomic_file.dart';
import 'package:image_editor/features/scanner/data/scan_repository.dart';
import 'package:image_editor/features/scanner/domain/models/scan_models.dart';

/// Behaviour tests for [ScanRepository].
///
/// The repo uses the same atomic-write primitive as [ProjectStore]. The
/// tests here cover:
/// - basic round-trip via the new `rootOverride` seam
/// - atomicity under a simulated mid-write crash
/// - no tmp files left behind on success
void main() {
  late Directory tmp;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('scan_repository_test');
    debugHookBeforeRename = null;
  });

  tearDown(() {
    debugHookBeforeRename = null;
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  /// Build a session with one page. `rawImagePath` points at an
  /// in-tmp placeholder file so the repo's page-copy step has
  /// something real to act on.
  ScanSession sampleSession({String id = 'session-1'}) {
    final raw = File('${tmp.path}/raw_$id.jpg')
      ..writeAsBytesSync([0xff, 0xd8, 0xff, 0xd9]); // minimal JPEG markers
    return ScanSession(
      id: id,
      pages: [
        ScanPage(id: 'page-1', rawImagePath: raw.path),
      ],
    );
  }

  group('ScanRepository round-trip', () {
    test('save → loadAll returns the persisted session', () async {
      final repo = ScanRepository(rootOverride: tmp);
      final session = sampleSession();
      await repo.save(session);
      final all = await repo.loadAll();
      expect(all.length, 1);
      expect(all.first.id, session.id);
      expect(all.first.pages.length, 1);
    });

    test('save twice for the same session overwrites prior state',
        () async {
      final repo = ScanRepository(rootOverride: tmp);
      final s1 = sampleSession();
      await repo.save(s1);
      // Second save with the same id but a different title.
      final s2 = s1.copyWith(title: 'Updated');
      await repo.save(s2);
      final all = await repo.loadAll();
      expect(all.length, 1);
      expect(all.first.title, 'Updated');
    });

    test('delete removes both the JSON and its per-session dir',
        () async {
      final repo = ScanRepository(rootOverride: tmp);
      final session = sampleSession();
      await repo.save(session);
      await repo.delete(session.id);
      final all = await repo.loadAll();
      expect(all, isEmpty);
      final sessionDir = Directory('${tmp.path}/${session.id}');
      expect(sessionDir.existsSync(), false);
    });
  });

  group('ScanRepository atomic save', () {
    test('crash between flush and rename preserves prior JSON', () async {
      final repo = ScanRepository(rootOverride: tmp);
      final first = sampleSession(id: 'atomic-1');
      await repo.save(first);
      expect((await repo.loadAll()).single.title, isNull);

      // Now simulate a crash mid-save on an update. The repo does NOT
      // catch the exception (unlike `ProjectStore.save` which is
      // fire-and-forget), so we expect the hook's throw to propagate.
      debugHookBeforeRename = () async {
        throw const FileSystemException('simulated crash');
      };
      final updated = first.copyWith(title: 'Lost update');
      await expectLater(
        () => repo.save(updated),
        throwsA(isA<FileSystemException>()),
      );

      // The prior session's JSON still loads intact.
      final all = await repo.loadAll();
      expect(all.single.id, first.id);
      expect(all.single.title, isNull,
          reason: 'the crashed save must not leak the "Lost update" title');
    });

    test('successful save leaves no .tmp sibling', () async {
      final repo = ScanRepository(rootOverride: tmp);
      await repo.save(sampleSession(id: 'clean'));
      final leftovers = tmp
          .listSync(recursive: false)
          .whereType<File>()
          .where((f) => f.path.endsWith('.tmp'))
          .toList();
      expect(leftovers, isEmpty);
    });

    test('crash cleans up the tmp sibling', () async {
      final repo = ScanRepository(rootOverride: tmp);
      debugHookBeforeRename = () async => throw StateError('simulated');
      await expectLater(
        () => repo.save(sampleSession(id: 'doomed')),
        throwsA(isA<StateError>()),
      );
      final leftovers = tmp
          .listSync(recursive: true)
          .whereType<File>()
          .where((f) => f.path.endsWith('.tmp'))
          .toList();
      expect(leftovers, isEmpty,
          reason: 'tmp must be removed when the write aborts');
    });
  });

  group('ScanRepository migration', () {
    test('loadAll upgrades a pre-schema (v0 unwrapped) file', () async {
      final repo = ScanRepository(rootOverride: tmp);
      // Hand-write a v0 file: the raw session JSON without the
      // `{schema, session}` wrapper, matching files saved by the
      // pre-versioning repo.
      final legacy = ScanSession(
        id: 'legacy-1',
        pages: [ScanPage(id: 'p1', rawImagePath: '/tmp/raw.jpg')],
      );
      File('${tmp.path}/legacy-1.json')
          .writeAsStringSync(jsonEncode(legacy.toJson()));

      final all = await repo.loadAll();
      expect(all.length, 1);
      expect(all.first.id, 'legacy-1');
      expect(all.first.pages.length, 1);
    });

    test('loadAll tolerates a future-version wrapper (best-effort)',
        () async {
      final repo = ScanRepository(rootOverride: tmp);
      final legacy = ScanSession(
        id: 'future-1',
        pages: [ScanPage(id: 'p1', rawImagePath: '/tmp/raw.jpg')],
      );
      // Wrap manually with a future schema so the migrator's
      // passthrough path is exercised.
      File('${tmp.path}/future-1.json').writeAsStringSync(
        jsonEncode({'schema': 99, 'session': legacy.toJson()}),
      );

      final all = await repo.loadAll();
      expect(all.length, 1);
      expect(all.first.id, 'future-1');
    });

    test('save writes a wrapped v1 envelope on disk', () async {
      final repo = ScanRepository(rootOverride: tmp);
      final session = ScanSession(
        id: 'fresh',
        pages: [
          ScanPage(
            id: 'p1',
            rawImagePath: (File('${tmp.path}/raw_fresh.jpg')
                  ..writeAsBytesSync([0xff, 0xd8, 0xff, 0xd9]))
                .path,
          ),
        ],
      );
      await repo.save(session);

      final onDisk = jsonDecode(
        File('${tmp.path}/fresh.json').readAsStringSync(),
      ) as Map<String, dynamic>;
      expect(onDisk['schema'], 1);
      expect(onDisk['session'], isA<Map<String, dynamic>>());
      expect((onDisk['session'] as Map)['id'], 'fresh');
    });
  });
}
