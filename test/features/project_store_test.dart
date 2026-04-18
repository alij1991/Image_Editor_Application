import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

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
  });

  tearDown(() {
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
    });
  });
}
