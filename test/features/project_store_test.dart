import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:image_editor/core/io/atomic_file.dart';
import 'package:image_editor/engine/pipeline/edit_op_type.dart';
import 'package:image_editor/engine/pipeline/edit_operation.dart';
import 'package:image_editor/engine/pipeline/edit_pipeline.dart';
import 'package:image_editor/features/editor/data/project_store.dart';

/// Behaviour tests for [ProjectStore]. Each test gets its own temp
/// directory injected via the `rootOverride` constructor knob so they
/// run in isolation and never touch the platform's documents
/// directory (which isn't available in pure flutter_test runs anyway).
void main() {
  late Directory tmp;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('project_store_test');
    // Residual hook from an unrelated atomic-write test would turn
    // every save into a crash.
    debugHookBeforeRename = null;
  });

  tearDown(() {
    debugHookBeforeRename = null;
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  EditPipeline samplePipeline(String path) =>
      EditPipeline.forOriginal(path).append(
        EditOperation.create(
          type: EditOpType.brightness,
          parameters: {'value': 0.42},
        ),
      ).append(
        EditOperation.create(
          type: EditOpType.vignette,
          parameters: {'amount': 0.3, 'feather': 0.4, 'roundness': 0.5},
        ),
      );

  group('ProjectStore', () {
    test('save → load round-trips the pipeline', () async {
      final store = ProjectStore(rootOverride: tmp);
      const path = '/tmp/photo.jpg';
      final original = samplePipeline(path);
      await store.save(sourcePath: path, pipeline: original);

      final loaded = await store.load(path);
      expect(loaded, isNotNull);
      expect(loaded!.operations.length, original.operations.length);
      expect(loaded.operations.first.type, EditOpType.brightness);
      expect(loaded.operations.first.parameters['value'], 0.42);
      expect(loaded.operations.last.type, EditOpType.vignette);
      expect(loaded.operations.last.parameters['feather'], 0.4);
    });

    test('load returns null when nothing has been saved for the path',
        () async {
      final store = ProjectStore(rootOverride: tmp);
      final loaded = await store.load('/tmp/never_saved.jpg');
      expect(loaded, isNull);
    });

    test('different source paths get different files', () async {
      final store = ProjectStore(rootOverride: tmp);
      await store.save(
        sourcePath: '/tmp/a.jpg',
        pipeline: samplePipeline('/tmp/a.jpg'),
      );
      await store.save(
        sourcePath: '/tmp/b.jpg',
        pipeline: EditPipeline.forOriginal('/tmp/b.jpg').append(
          EditOperation.create(
            type: EditOpType.contrast,
            parameters: {'value': 0.5},
          ),
        ),
      );
      final a = await store.load('/tmp/a.jpg');
      final b = await store.load('/tmp/b.jpg');
      expect(a!.operations.first.type, EditOpType.brightness);
      expect(b!.operations.first.type, EditOpType.contrast);
    });

    test('save twice for the same path overwrites previous state', () async {
      final store = ProjectStore(rootOverride: tmp);
      const path = '/tmp/photo.jpg';
      await store.save(
        sourcePath: path,
        pipeline: EditPipeline.forOriginal(path).append(
          EditOperation.create(
            type: EditOpType.brightness,
            parameters: {'value': 0.1},
          ),
        ),
      );
      await store.save(
        sourcePath: path,
        pipeline: EditPipeline.forOriginal(path).append(
          EditOperation.create(
            type: EditOpType.saturation,
            parameters: {'value': -0.5},
          ),
        ),
      );
      final loaded = await store.load(path);
      expect(loaded!.operations.length, 1);
      expect(loaded.operations.first.type, EditOpType.saturation);
    });

    test('delete removes the persisted file', () async {
      final store = ProjectStore(rootOverride: tmp);
      const path = '/tmp/photo.jpg';
      await store.save(sourcePath: path, pipeline: samplePipeline(path));
      expect(await store.load(path), isNotNull);
      await store.delete(path);
      expect(await store.load(path), isNull);
    });

    test('delete on a never-saved path is a no-op', () async {
      final store = ProjectStore(rootOverride: tmp);
      // Should not throw.
      await store.delete('/tmp/never_saved.jpg');
    });

    test('load returns null when JSON is malformed', () async {
      final store = ProjectStore(rootOverride: tmp);
      const path = '/tmp/photo.jpg';
      // Save then corrupt the file.
      await store.save(sourcePath: path, pipeline: samplePipeline(path));
      final files = tmp.listSync();
      expect(files, isNotEmpty);
      await (files.first as File).writeAsString('this is not json');
      final loaded = await store.load(path);
      expect(loaded, isNull);
    });

    test('load returns null when schema is missing or wrong', () async {
      final store = ProjectStore(rootOverride: tmp);
      const path = '/tmp/photo.jpg';
      await store.save(sourcePath: path, pipeline: samplePipeline(path));
      final files = tmp.listSync();
      // Replace the schema with a wrong one.
      await (files.first as File).writeAsString(
        '{"schema": 999, "pipeline": {}}',
      );
      final loaded = await store.load(path);
      expect(loaded, isNull);
    });

    test('save persists empty pipelines too', () async {
      final store = ProjectStore(rootOverride: tmp);
      const path = '/tmp/photo.jpg';
      await store.save(
        sourcePath: path,
        pipeline: EditPipeline.forOriginal(path),
      );
      final loaded = await store.load(path);
      expect(loaded, isNotNull);
      expect(loaded!.operations, isEmpty);
    });
  });

  group('ProjectStore.list', () {
    test('returns empty when nothing has been saved', () async {
      final store = ProjectStore(rootOverride: tmp);
      final all = await store.list();
      expect(all, isEmpty);
    });

    test('returns one summary per saved project, newest-first', () async {
      final store = ProjectStore(rootOverride: tmp);
      // Save three with deliberate ordering so we can assert sort.
      await store.save(
        sourcePath: '/tmp/a.jpg',
        pipeline: samplePipeline('/tmp/a.jpg'),
      );
      await Future.delayed(const Duration(milliseconds: 5));
      await store.save(
        sourcePath: '/tmp/b.jpg',
        pipeline: samplePipeline('/tmp/b.jpg'),
      );
      await Future.delayed(const Duration(milliseconds: 5));
      await store.save(
        sourcePath: '/tmp/c.jpg',
        pipeline: samplePipeline('/tmp/c.jpg'),
      );
      final all = await store.list();
      expect(all.length, 3);
      // c was saved last → first in the list.
      expect(all.first.sourcePath, '/tmp/c.jpg');
      expect(all.last.sourcePath, '/tmp/a.jpg');
      for (final s in all) {
        expect(s.opCount, 2);
        expect(s.savedAt, isNotNull);
      }
    });

    test('skips entries with bad schema or malformed JSON', () async {
      final store = ProjectStore(rootOverride: tmp);
      await store.save(
        sourcePath: '/tmp/good.jpg',
        pipeline: samplePipeline('/tmp/good.jpg'),
      );
      // Drop a corrupt file alongside the good one.
      File('${tmp.path}/garbage.json').writeAsStringSync('not json');
      File('${tmp.path}/wrong_schema.json')
          .writeAsStringSync('{"schema": 999}');
      final all = await store.list();
      expect(all.length, 1);
      expect(all.first.sourcePath, '/tmp/good.jpg');
    });
  });

  group('ProjectSummary', () {
    test('exposes sourcePath, savedAt, opCount, jsonFile', () async {
      final store = ProjectStore(rootOverride: tmp);
      await store.save(
        sourcePath: '/tmp/a.jpg',
        pipeline: samplePipeline('/tmp/a.jpg'),
      );
      final all = await store.list();
      final s = all.single;
      expect(s.sourcePath, '/tmp/a.jpg');
      expect(s.opCount, 2);
      expect(s.jsonFile.existsSync(), true);
      expect(s.savedAt.isAfter(DateTime.now().subtract(const Duration(minutes: 1))), true);
      expect(s.customTitle, isNull);
    });

    test('displayLabel falls back to filename when customTitle is null',
        () async {
      final store = ProjectStore(rootOverride: tmp);
      await store.save(
        sourcePath: '/tmp/IMG_001.jpg',
        pipeline: samplePipeline('/tmp/IMG_001.jpg'),
      );
      final s = (await store.list()).single;
      expect(s.displayLabel('IMG_001.jpg'), 'IMG_001.jpg');
    });

    test('displayLabel returns customTitle when set', () async {
      final store = ProjectStore(rootOverride: tmp);
      await store.save(
        sourcePath: '/tmp/IMG_001.jpg',
        pipeline: samplePipeline('/tmp/IMG_001.jpg'),
        customTitle: 'Trip to Big Sur',
      );
      final s = (await store.list()).single;
      expect(s.displayLabel('IMG_001.jpg'), 'Trip to Big Sur');
      expect(s.customTitle, 'Trip to Big Sur');
    });
  });

  group('ProjectStore migration', () {
    test('load migrates a pre-schema (v0) wrapper', () async {
      final store = ProjectStore(rootOverride: tmp);
      const path = '/tmp/photo.jpg';
      // First save at v1, then rewrite the file stripping the schema
      // field to simulate a project file that predates the wrapper
      // versioning. The migrator must treat it as v0 and carry it
      // forward without dropping the pipeline.
      await store.save(sourcePath: path, pipeline: samplePipeline(path));
      final file = tmp.listSync().single as File;
      final decoded = jsonDecode(await file.readAsString())
          as Map<String, dynamic>;
      decoded.remove('schema');
      await file.writeAsString(jsonEncode(decoded));

      final loaded = await store.load(path);
      expect(loaded, isNotNull);
      expect(loaded!.operations.length, 2);
      expect(loaded.operations.first.type, EditOpType.brightness);
    });

    test('load tolerates a future-version wrapper (best-effort parse)',
        () async {
      final store = ProjectStore(rootOverride: tmp);
      const path = '/tmp/photo.jpg';
      await store.save(sourcePath: path, pipeline: samplePipeline(path));
      final file = tmp.listSync().single as File;
      final decoded = jsonDecode(await file.readAsString())
          as Map<String, dynamic>;
      decoded['schema'] = 99;
      await file.writeAsString(jsonEncode(decoded));

      final loaded = await store.load(path);
      // Future version is best-effort; the pipeline still loads as
      // long as its shape holds.
      expect(loaded, isNotNull);
      expect(loaded!.operations.length, 2);
    });

    test('list migrates a pre-schema entry rather than dropping it',
        () async {
      final store = ProjectStore(rootOverride: tmp);
      const path = '/tmp/photo.jpg';
      await store.save(sourcePath: path, pipeline: samplePipeline(path));
      final file = tmp.listSync().single as File;
      final decoded = jsonDecode(await file.readAsString())
          as Map<String, dynamic>;
      decoded.remove('schema');
      await file.writeAsString(jsonEncode(decoded));

      final all = await store.list();
      expect(all.length, 1);
      expect(all.first.sourcePath, path);
    });
  });

  group('ProjectStore atomic save', () {
    test('crash between flush and rename preserves prior content',
        () async {
      final store = ProjectStore(rootOverride: tmp);
      const path = '/tmp/photo.jpg';
      // First save: the good pipeline that must survive.
      final good = samplePipeline(path);
      await store.save(sourcePath: path, pipeline: good);
      final goodLoaded = await store.load(path);
      expect(goodLoaded, isNotNull);
      expect(goodLoaded!.operations.length, good.operations.length);

      // Simulate a crash mid-save on the SECOND write. `ProjectStore`
      // swallows IO exceptions (auto-save is fire-and-forget) so we
      // don't expect a throw at the call site — just verify the
      // on-disk state is still the first save's content.
      debugHookBeforeRename = () async {
        throw const FileSystemException('simulated crash');
      };
      await store.save(
        sourcePath: path,
        pipeline: EditPipeline.forOriginal(path).append(
          EditOperation.create(
            type: EditOpType.contrast,
            parameters: {'value': -0.9},
          ),
        ),
      );

      // The first save's state survives the crashed second save.
      final recovered = await store.load(path);
      expect(recovered, isNotNull);
      expect(recovered!.operations.length, good.operations.length);
      expect(recovered.operations.first.type, EditOpType.brightness);
      expect(recovered.operations.first.parameters['value'], 0.42);
    });

    test('crash on the first-ever save leaves no target file', () async {
      final store = ProjectStore(rootOverride: tmp);
      const path = '/tmp/never_saved.jpg';
      debugHookBeforeRename = () async {
        throw StateError('simulated crash');
      };
      await store.save(sourcePath: path, pipeline: samplePipeline(path));
      // `load` returns null both for "missing" and for parse-errors.
      expect(await store.load(path), isNull);
      // And no .tmp sibling should linger.
      final leftovers = tmp
          .listSync()
          .whereType<File>()
          .where((f) => f.path.endsWith('.tmp'))
          .toList();
      expect(leftovers, isEmpty,
          reason: 'tmp file must be cleaned up when save aborts');
    });

    test('successful save leaves no .tmp sibling', () async {
      final store = ProjectStore(rootOverride: tmp);
      const path = '/tmp/photo.jpg';
      await store.save(sourcePath: path, pipeline: samplePipeline(path));
      final leftovers = tmp
          .listSync()
          .whereType<File>()
          .where((f) => f.path.endsWith('.tmp'))
          .toList();
      expect(leftovers, isEmpty);
    });
  });

  group('ProjectStore custom title persistence', () {
    test('save with customTitle persists across save→load', () async {
      final store = ProjectStore(rootOverride: tmp);
      const path = '/tmp/photo.jpg';
      await store.save(
        sourcePath: path,
        pipeline: samplePipeline(path),
        customTitle: 'Sunset shoot',
      );
      final list = await store.list();
      expect(list.single.customTitle, 'Sunset shoot');
    });

    test('subsequent save without customTitle preserves the existing one',
        () async {
      // The auto-save path doesn't pass a title, so renames must
      // survive every committed slider tick.
      final store = ProjectStore(rootOverride: tmp);
      const path = '/tmp/photo.jpg';
      await store.save(
        sourcePath: path,
        pipeline: samplePipeline(path),
        customTitle: 'Sunset shoot',
      );
      // Auto-save with no title.
      await store.save(sourcePath: path, pipeline: samplePipeline(path));
      final list = await store.list();
      expect(list.single.customTitle, 'Sunset shoot');
    });

    test('save with empty customTitle clears the title', () async {
      final store = ProjectStore(rootOverride: tmp);
      const path = '/tmp/photo.jpg';
      await store.save(
        sourcePath: path,
        pipeline: samplePipeline(path),
        customTitle: 'Sunset shoot',
      );
      await store.save(
        sourcePath: path,
        pipeline: samplePipeline(path),
        customTitle: '',
      );
      final list = await store.list();
      expect(list.single.customTitle, isNull);
    });
  });
}
