import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:image_editor/engine/pipeline/edit_op_type.dart';
import 'package:image_editor/engine/pipeline/edit_operation.dart';
import 'package:image_editor/engine/pipeline/edit_pipeline.dart';
import 'package:image_editor/engine/presets/preset_repository.dart';

/// Schema-migration behaviour tests for [PresetRepository] — the
/// Phase IV.3 deliverable. Phase I.2 landed the `onUpgrade` handler
/// registration; this file is the regression target that pins it.
///
/// The `sqflite` plugin needs a platform channel we don't have in
/// `flutter_test`, so `setUpAll` swaps the factory for the FFI-backed
/// implementation (bundled sqlite via the `sqflite_common_ffi` dev
/// dependency). This keeps the real `PresetRepository` code path —
/// including its `openDatabase` call — under test.
///
/// Scenarios pinned:
///   - Fresh open at v1 creates the `presets` table.
///   - A preset saved at v1 survives close + reopen.
///   - Synthetic v1 → v2 upgrade: existing v1 data lives through a
///     bumped `openDatabase(version: 2, onUpgrade: runUpgrade)`.
///   - Multi-step v1 → v5 upgrade: handler tolerates big version
///     jumps without crashing.
///   - `runUpgrade` is idempotent on repeated calls at the same
///     version boundary.
///   - `currentDbVersion` pins the shipped integer so a drift between
///     code and test never passes silently.
void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  late Directory tmp;
  late String dbPath;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('preset_repo_schema_test');
    dbPath = p.join(tmp.path, 'presets.db');
  });

  tearDown(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  EditPipeline samplePipeline() =>
      EditPipeline.forOriginal('/tmp/shot.jpg').append(
        EditOperation.create(
          type: EditOpType.brightness,
          parameters: {'value': 0.2},
        ),
      );

  group('PresetRepository schema', () {
    test('currentDbVersion pins the shipped schema integer', () {
      // Acts as a tripwire: changing [currentDbVersion] without
      // updating this test surfaces the bump at review time.
      expect(PresetRepository.currentDbVersion, 1);
    });

    test('fresh open at v1 creates the presets table', () async {
      final repo = PresetRepository(dbPathOverride: dbPath);
      // loadCustom forces `_openDb`, which triggers onCreate for a
      // missing file.
      final loaded = await repo.loadCustom();
      expect(loaded, isEmpty);
      await repo.close();

      // Verify the table actually exists + user_version was stamped.
      final db = await openDatabase(dbPath);
      final tables = await db.query(
        'sqlite_master',
        columns: ['name'],
        where: 'type = ? AND name = ?',
        whereArgs: ['table', 'presets'],
      );
      expect(tables, hasLength(1));
      final version =
          await db.rawQuery('PRAGMA user_version').then((r) => r.first);
      expect(version['user_version'], 1);
      await db.close();
    });

    test('preset saved at v1 survives close + reopen', () async {
      // Baseline persistence before stressing the migration seam —
      // catches regressions in `_rowToPreset` without dragging in
      // the upgrade machinery.
      final repo1 = PresetRepository(dbPathOverride: dbPath);
      final saved = await repo1.saveFromPipeline(
        name: 'Cozy dusk',
        pipeline: samplePipeline(),
      );
      await repo1.close();

      final repo2 = PresetRepository(dbPathOverride: dbPath);
      final all = await repo2.loadCustom();
      await repo2.close();

      expect(all, hasLength(1));
      expect(all.single.id, saved.id);
      expect(all.single.name, 'Cozy dusk');
      expect(all.single.operations, hasLength(1));
      expect(all.single.operations.first.type, EditOpType.brightness);
    });
  });

  group('PresetRepository onUpgrade', () {
    test('synthetic v1 → v2 bump runs handler without crashing', () async {
      // 1. Land a v1 database populated with one row.
      final repo = PresetRepository(dbPathOverride: dbPath);
      await repo.saveFromPipeline(
        name: 'Legacy v1 preset',
        pipeline: samplePipeline(),
      );
      await repo.close();

      // 2. Reopen at v2 directly, routing sqflite's onUpgrade to the
      //    exact handler `PresetRepository._openDb` registers. The
      //    test captures the (oldVersion, newVersion) pair so we can
      //    assert the seam fires rather than trusting "no throw".
      final upgradeCalls = <List<int>>[];
      final db = await openDatabase(
        dbPath,
        version: 2,
        onCreate: (db, v) =>
            throw StateError('onCreate must not fire for an existing db'),
        onUpgrade: (db, oldVersion, newVersion) async {
          upgradeCalls.add([oldVersion, newVersion]);
          await PresetRepository.runUpgrade(db, oldVersion, newVersion);
        },
      );

      // 3. Assert the handler ran with the expected boundaries.
      expect(upgradeCalls, [
        [1, 2]
      ]);

      // 4. Assert the row from v1 survived the upgrade (the stub must
      //    not drop rows; when real migrations land they must preserve
      //    data unless an explicit DROP step is added).
      final rows = await db.query('presets');
      expect(rows, hasLength(1));
      expect(rows.single['name'], 'Legacy v1 preset');

      // 5. Assert user_version was actually bumped.
      final version =
          await db.rawQuery('PRAGMA user_version').then((r) => r.first);
      expect(version['user_version'], 2);

      await db.close();
    });

    test('multi-step v1 → v5 upgrade still fires once + preserves data',
        () async {
      // Models a user who skips several releases. Sqflite calls
      // onUpgrade once with (oldVersion: 1, newVersion: 5); the handler
      // is responsible for walking every missing step internally.
      // Today's stub is a no-op — the contract under test is that the
      // big jump doesn't crash and doesn't clobber data.
      final repo = PresetRepository(dbPathOverride: dbPath);
      await repo.saveFromPipeline(
        name: 'v1 preset',
        pipeline: samplePipeline(),
      );
      await repo.close();

      final upgradeCalls = <List<int>>[];
      final db = await openDatabase(
        dbPath,
        version: 5,
        onUpgrade: (db, oldVersion, newVersion) async {
          upgradeCalls.add([oldVersion, newVersion]);
          await PresetRepository.runUpgrade(db, oldVersion, newVersion);
        },
      );

      expect(upgradeCalls, [
        [1, 5]
      ],
          reason: 'sqflite collapses missing steps into one callback');
      expect((await db.query('presets')), hasLength(1));
      await db.close();
    });

    test('runUpgrade called directly is a no-op (stub invariant)',
        () async {
      // Pins the "no-op beyond logging" promise in the handler's
      // docstring. When the first real migration lands, this test
      // either updates to reflect the new schema or splits into
      // v1→v2 / v2→v3 etc. cases — either way the drift surfaces
      // at review time.
      final db = await openDatabase(dbPath, version: 1,
          onCreate: (db, v) async {
        // Minimal create so a subsequent query has a table to hit.
        await db.execute('''
          CREATE TABLE IF NOT EXISTS presets (
            id TEXT PRIMARY KEY,
            name TEXT NOT NULL,
            json TEXT NOT NULL,
            created_at INTEGER NOT NULL
          )
        ''');
      });
      await db.insert('presets', {
        'id': 'p1',
        'name': 'probe',
        'json': '{"operations":[]}',
        'created_at': 0,
      });

      // Direct invocation — sanity that the handler neither throws
      // nor mutates the table.
      await PresetRepository.runUpgrade(db, 0, 1);
      await PresetRepository.runUpgrade(db, 1, 2);
      await PresetRepository.runUpgrade(db, 1, 42);

      final rows = await db.query('presets');
      expect(rows, hasLength(1));
      expect(rows.single['name'], 'probe');
      await db.close();
    });

    test('reopening at the same version does NOT fire onUpgrade',
        () async {
      // Idempotence: opening a v1 DB with a v1 factory must not walk
      // the migration chain. This pins the sqflite semantics we rely
      // on — the seam is gated by the (oldVersion < newVersion)
      // check, so no handler runs on a version-match open.
      final repo1 = PresetRepository(dbPathOverride: dbPath);
      await repo1.loadCustom();
      await repo1.close();

      var upgradeCalled = false;
      final db = await openDatabase(
        dbPath,
        version: 1,
        onUpgrade: (_, _, _) async {
          upgradeCalled = true;
        },
      );
      expect(upgradeCalled, isFalse);
      await db.close();
    });
  });
}
