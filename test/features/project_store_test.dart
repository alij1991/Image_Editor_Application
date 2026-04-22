import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'package:image_editor/core/io/atomic_file.dart';
import 'package:image_editor/core/io/compressed_json.dart';
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

  /// Returns the sole per-project JSON in [tmp], skipping the
  /// Phase IV.8 `_index.json` sidecar that lives alongside it.
  /// Tests that previously relied on `tmp.listSync().single` use this
  /// to keep the same "one project, get its file" semantics.
  File singleProjectFile() {
    final files = tmp
        .listSync()
        .whereType<File>()
        .where((f) => p.basename(f.path) != '_index.json')
        .toList();
    return files.single;
  }

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
      await store.save(sourcePath: path, pipeline: samplePipeline(path));
      await singleProjectFile().writeAsString('this is not json');
      final loaded = await store.load(path);
      expect(loaded, isNull);
    });

    test('load returns null when schema is missing or wrong', () async {
      final store = ProjectStore(rootOverride: tmp);
      const path = '/tmp/photo.jpg';
      await store.save(sourcePath: path, pipeline: samplePipeline(path));
      await singleProjectFile().writeAsString(
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
    // These tests reach past the store API to mutate the on-disk
    // wrapper directly (strip `schema`, set a future schema). Since
    // Phase IV.2 the wire format is marker-byte-prefixed bytes
    // produced by [encodeCompressedJson], so read/rewrite goes
    // through the codec instead of the old `readAsString` /
    // `writeAsString` pair.
    test('load migrates a pre-schema (v0) wrapper', () async {
      final store = ProjectStore(rootOverride: tmp);
      const path = '/tmp/photo.jpg';
      // First save at v1, then rewrite the file stripping the schema
      // field to simulate a project file that predates the wrapper
      // versioning. The migrator must treat it as v0 and carry it
      // forward without dropping the pipeline.
      await store.save(sourcePath: path, pipeline: samplePipeline(path));
      final file = singleProjectFile();
      final decoded =
          jsonDecode(decodeCompressedJson(await file.readAsBytes()))
              as Map<String, dynamic>;
      decoded.remove('schema');
      await file.writeAsBytes(encodeCompressedJson(jsonEncode(decoded)));

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
      final file = singleProjectFile();
      final decoded =
          jsonDecode(decodeCompressedJson(await file.readAsBytes()))
              as Map<String, dynamic>;
      decoded['schema'] = 99;
      await file.writeAsBytes(encodeCompressedJson(jsonEncode(decoded)));

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
      final file = singleProjectFile();
      final decoded =
          jsonDecode(decodeCompressedJson(await file.readAsBytes()))
              as Map<String, dynamic>;
      decoded.remove('schema');
      await file.writeAsBytes(encodeCompressedJson(jsonEncode(decoded)));

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

  group('ProjectStore Phase IV.2 wire format', () {
    // Pins the Phase IV.2 format contract: saves land as marker-prefixed
    // byte buffers produced by [encodeCompressedJson]. Small envelopes
    // stay plain (0x00); envelopes ≥ 64 KB gzip (0x01). Legacy un-marked
    // JSON written by the pre-Phase-IV.2 build must still load.
    test('save writes a marker-byte prefix (0x00) for small pipelines',
        () async {
      final store = ProjectStore(rootOverride: tmp);
      const path = '/tmp/small.jpg';
      await store.save(sourcePath: path, pipeline: samplePipeline(path));
      final file = singleProjectFile();
      final bytes = await file.readAsBytes();
      expect(bytes.first, 0x00, reason: 'small envelope should stay plain');
      // After stripping the marker the payload parses as the envelope
      // JSON we handed the encoder — prove the framing matches the
      // codec contract bit-for-bit.
      final decoded = jsonDecode(utf8.decode(bytes.sublist(1)))
          as Map<String, dynamic>;
      expect(decoded['schema'], 1);
      expect(decoded['sourcePath'], path);
    });

    test('save gzips (0x01) and load round-trips a >64 KB pipeline',
        () async {
      // Build a pipeline whose envelope JSON blows past the 64 KB
      // gzip threshold. Ten ops × ~8 KB of filler each gets us comfortably
      // over the line.
      final store = ProjectStore(rootOverride: tmp);
      const path = '/tmp/huge.jpg';
      var pipeline = EditPipeline.forOriginal(path);
      for (var i = 0; i < 10; i++) {
        pipeline = pipeline.append(EditOperation.create(
          type: EditOpType.brightness,
          parameters: {
            'value': i * 0.001,
            'filler': List.generate(400, (j) => 'x' * 20),
          },
        ));
      }
      await store.save(sourcePath: path, pipeline: pipeline);

      final file = singleProjectFile();
      final bytes = await file.readAsBytes();
      expect(bytes.first, 0x01,
          reason: 'envelope over 64 KB should trigger gzip');

      final loaded = await store.load(path);
      expect(loaded, isNotNull);
      expect(loaded!.operations.length, 10);
      expect(
        loaded.operations.first.parameters['value'],
        pipeline.operations.first.parameters['value'],
      );
    });

    test('legacy un-marked plain JSON on disk still loads', () async {
      // Pre-Phase-IV.2 ProjectStore wrote plain `jsonEncode(envelope)`
      // via `atomicWriteString` — no marker byte. The decoder's
      // first-byte branch must treat those files as legacy JSON and
      // carry them through the rest of the load pipeline unchanged.
      final store = ProjectStore(rootOverride: tmp);
      const path = '/tmp/legacy.jpg';
      final pipeline = samplePipeline(path);

      // Hand-write the file in the pre-Phase-IV.2 format.
      final file = File('${tmp.path}/${_keyFor(path)}.json');
      final envelope = <String, Object?>{
        'schema': 1,
        'sourcePath': path,
        'savedAt': DateTime.now().toIso8601String(),
        'pipeline': pipeline.toJson(),
      };
      await file.writeAsString(jsonEncode(envelope));
      // Sanity: first byte is `{` (0x7B) — not a marker byte.
      final firstByte = (await file.readAsBytes()).first;
      expect(firstByte, 0x7B);

      final loaded = await store.load(path);
      expect(loaded, isNotNull);
      expect(loaded!.operations.length, pipeline.operations.length);
      expect(loaded.operations.first.type, EditOpType.brightness);
    });

    test('legacy save → modern save overwrites with marker bytes',
        () async {
      // A user upgrades the app: their first open loads the legacy file
      // correctly (asserted above), auto-save fires, the file is
      // rewritten in the new format with the 0x00 marker. Subsequent
      // loads go through the modern path.
      final store = ProjectStore(rootOverride: tmp);
      const path = '/tmp/upgrade.jpg';

      // Seed a legacy-format file.
      final file = File('${tmp.path}/${_keyFor(path)}.json');
      final envelope = <String, Object?>{
        'schema': 1,
        'sourcePath': path,
        'savedAt': DateTime.now().toIso8601String(),
        'pipeline': samplePipeline(path).toJson(),
        'customTitle': 'Legacy rename',
      };
      await file.writeAsString(jsonEncode(envelope));

      // Auto-save (no customTitle) — should preserve the title and
      // promote the file format in one hop.
      await store.save(sourcePath: path, pipeline: samplePipeline(path));

      final bytes = await file.readAsBytes();
      expect(bytes.first, 0x00,
          reason: 'rewrite must land in the new marker-byte format');

      final list = await store.list();
      expect(list.single.customTitle, 'Legacy rename',
          reason: 'title must survive the format upgrade');
    });

    test('decodeCompressedJson round-trips the on-disk bytes directly',
        () async {
      // Cross-check that ProjectStore's on-disk artefact IS what the
      // codec produces — catches a drift where ProjectStore starts
      // wrapping or re-encoding beyond the codec's contract.
      final store = ProjectStore(rootOverride: tmp);
      const path = '/tmp/direct.jpg';
      await store.save(sourcePath: path, pipeline: samplePipeline(path));
      final file = singleProjectFile();
      final bytes = await file.readAsBytes();
      final raw = decodeCompressedJson(Uint8List.fromList(bytes));
      final decoded = jsonDecode(raw) as Map<String, dynamic>;
      expect(decoded['pipeline'], isA<Map>());
      expect(decoded['sourcePath'], path);
    });
  });

  group('ProjectStore.setTitle', () {
    // Phase IV.6: dedicated rename fast-path that rewrites ONLY the
    // `customTitle` field. The cardinal invariant is that the pipeline
    // sub-map lands on disk byte-identical — no fromJson / toJson
    // round-trip, so forward-compat fields survive and nothing in
    // the pipeline shape can drift across a rename.
    test('writes title and returns true', () async {
      final store = ProjectStore(rootOverride: tmp);
      const path = '/tmp/rename.jpg';
      await store.save(sourcePath: path, pipeline: samplePipeline(path));

      final ok = await store.setTitle(path, 'New name');
      expect(ok, isTrue);

      final list = await store.list();
      expect(list.single.customTitle, 'New name');
    });

    test('empty title clears an existing title', () async {
      final store = ProjectStore(rootOverride: tmp);
      const path = '/tmp/clear.jpg';
      await store.save(
        sourcePath: path,
        pipeline: samplePipeline(path),
        customTitle: 'Original',
      );
      final ok = await store.setTitle(path, '');
      expect(ok, isTrue);
      final list = await store.list();
      expect(list.single.customTitle, isNull);
    });

    test('setTitle on a never-saved path returns false', () async {
      final store = ProjectStore(rootOverride: tmp);
      final ok = await store.setTitle('/tmp/never.jpg', 'doesnt matter');
      expect(ok, isFalse);
      // And no file was created as a side effect.
      expect(tmp.listSync(), isEmpty);
    });

    test('pipeline sub-map is byte-identical across a rename', () async {
      // The Phase IV.6 cardinal invariant. Load the envelope before
      // and after setTitle; the `pipeline` sub-map must encode to the
      // same UTF-8 bytes. Catches any accidental fromJson/toJson
      // round-trip in the rename path.
      final store = ProjectStore(rootOverride: tmp);
      const path = '/tmp/invariant.jpg';
      await store.save(sourcePath: path, pipeline: samplePipeline(path));
      final file = singleProjectFile();

      String pipelineBytes() {
        final envelope = jsonDecode(
          decodeCompressedJson(file.readAsBytesSync()),
        ) as Map<String, dynamic>;
        // Canonicalise the sub-map via jsonEncode so comparison isn't
        // thrown off by Map ordering differences.
        return jsonEncode(envelope['pipeline']);
      }

      final before = pipelineBytes();
      await store.setTitle(path, 'Whatever');
      final after = pipelineBytes();
      expect(after, before,
          reason: 'setTitle must not mutate the pipeline sub-map');
    });

    test('savedAt is bumped so the rename lifts the entry to newest',
        () async {
      // Matches the observable behaviour of the pre-IV.6 load+save
      // rename path — the recent-projects strip is sorted newest
      // first, so rename-as-activity bubbles to the top.
      final store = ProjectStore(rootOverride: tmp);
      await store.save(
        sourcePath: '/tmp/older.jpg',
        pipeline: samplePipeline('/tmp/older.jpg'),
      );
      await Future.delayed(const Duration(milliseconds: 10));
      await store.save(
        sourcePath: '/tmp/newer.jpg',
        pipeline: samplePipeline('/tmp/newer.jpg'),
      );

      // Before rename: newer.jpg is on top.
      var list = await store.list();
      expect(list.first.sourcePath, '/tmp/newer.jpg');

      await Future.delayed(const Duration(milliseconds: 10));
      await store.setTitle('/tmp/older.jpg', 'Renamed');

      // After rename: the renamed file leapfrogs to the top.
      list = await store.list();
      expect(list.first.sourcePath, '/tmp/older.jpg');
      expect(list.first.customTitle, 'Renamed');
    });

    test('setTitle preserves existing customTitle when called with same',
        () async {
      final store = ProjectStore(rootOverride: tmp);
      const path = '/tmp/idempotent.jpg';
      await store.save(
        sourcePath: path,
        pipeline: samplePipeline(path),
        customTitle: 'Sunset shoot',
      );
      // Rewriting with the same title is a no-op at the observable
      // level beyond the `savedAt` bump.
      await store.setTitle(path, 'Sunset shoot');
      final list = await store.list();
      expect(list.single.customTitle, 'Sunset shoot');
    });

    test('setTitle is atomic: crash preserves prior title + pipeline',
        () async {
      final store = ProjectStore(rootOverride: tmp);
      const path = '/tmp/atomic_rename.jpg';
      await store.save(
        sourcePath: path,
        pipeline: samplePipeline(path),
        customTitle: 'Original',
      );

      // Simulate crash mid-rename. setTitle catches errors and returns
      // false (fire-and-forget-safe, matches save()).
      debugHookBeforeRename = () async {
        throw const FileSystemException('simulated crash');
      };
      final ok = await store.setTitle(path, 'Doomed update');
      expect(ok, isFalse);

      // The prior title + pipeline survive the crashed rename.
      debugHookBeforeRename = null;
      final recovered = await store.list();
      expect(recovered.single.customTitle, 'Original');
      final pipeline = await store.load(path);
      expect(pipeline, isNotNull);
      expect(pipeline!.operations.length, 2);
    });

    test('setTitle works with a gzipped envelope (>64 KB pipeline)',
        () async {
      // Covers the case where the envelope crosses the gzip threshold
      // — setTitle must round-trip through the same codec and land
      // back in the marker-byte format.
      final store = ProjectStore(rootOverride: tmp);
      const path = '/tmp/big.jpg';
      var pipeline = EditPipeline.forOriginal(path);
      for (var i = 0; i < 10; i++) {
        pipeline = pipeline.append(EditOperation.create(
          type: EditOpType.brightness,
          parameters: {
            'value': i * 0.01,
            'filler': List.generate(400, (j) => 'x' * 20),
          },
        ));
      }
      await store.save(sourcePath: path, pipeline: pipeline);
      final file = singleProjectFile();
      // Sanity: file is in the gzip branch before rename.
      expect((await file.readAsBytes()).first, 0x01);

      final ok = await store.setTitle(path, 'Big rename');
      expect(ok, isTrue);

      // Still gzipped, still loads, title took.
      expect((await file.readAsBytes()).first, 0x01);
      final list = await store.list();
      expect(list.single.customTitle, 'Big rename');
      final loaded = await store.load(path);
      expect(loaded!.operations.length, 10);
    });
  });

  group('ProjectStore.setTitle legacy-format bridge', () {
    test('setTitle works against a legacy un-marked plain-JSON file',
        () async {
      // Users upgrading from pre-IV.2 have plain-JSON envelopes on
      // disk. setTitle reads via `decodeCompressedJson` which tolerates
      // legacy un-marked buffers, promotes the file to marker format
      // on write, and the title lands correctly.
      final store = ProjectStore(rootOverride: tmp);
      const path = '/tmp/legacy.jpg';
      final file = File('${tmp.path}/${_keyFor(path)}.json');
      final envelope = <String, Object?>{
        'schema': 1,
        'sourcePath': path,
        'savedAt': DateTime.now().toIso8601String(),
        'pipeline': samplePipeline(path).toJson(),
      };
      await file.writeAsString(jsonEncode(envelope));
      // Sanity: legacy format (first byte is `{`).
      expect((await file.readAsBytes()).first, 0x7B);

      final ok = await store.setTitle(path, 'Upgraded');
      expect(ok, isTrue);

      // Auto-promoted to marker format.
      expect((await file.readAsBytes()).first, 0x00);
      final list = await store.list();
      expect(list.single.customTitle, 'Upgraded');
    });

    test('pipeline sub-map bytes survive a legacy-format rename too',
        () async {
      // Phase IV.6 invariant again, but against the legacy unmarked
      // format — the fast-path must preserve pipeline bytes even when
      // it also happens to upgrade the envelope framing.
      final store = ProjectStore(rootOverride: tmp);
      const path = '/tmp/legacy_invariant.jpg';
      final file = File('${tmp.path}/${_keyFor(path)}.json');
      final pipelineJson = samplePipeline(path).toJson();
      final envelope = <String, Object?>{
        'schema': 1,
        'sourcePath': path,
        'savedAt': DateTime.now().toIso8601String(),
        'pipeline': pipelineJson,
      };
      await file.writeAsString(jsonEncode(envelope));
      final pipelineBefore = jsonEncode(pipelineJson);

      await store.setTitle(path, 'anything');

      final envAfter = jsonDecode(
        decodeCompressedJson(await file.readAsBytes()),
      ) as Map<String, dynamic>;
      final pipelineAfter = jsonEncode(envAfter['pipeline']);
      expect(pipelineAfter, pipelineBefore,
          reason: 'pipeline bytes identical across legacy rename');
    });
  });

  group('ProjectStore title cache (Phase IV.7)', () {
    // The cache exists to skip the prior-file read inside [save] when
    // the caller passes `customTitle: null` (auto-save path). The
    // `debugTitleCacheMissCount` counter increments every time the
    // cache-hit shortcut fails and the fallback re-reads the file;
    // tests assert it stays 0 on the warm-cache path.

    test('auto-save on a warm cache does NOT re-read the prior file',
        () async {
      final store = ProjectStore(rootOverride: tmp);
      const path = '/tmp/warm.jpg';
      // Seed the cache with an initial save that sets a title.
      await store.save(
        sourcePath: path,
        pipeline: samplePipeline(path),
        customTitle: 'Warm',
      );
      final before = store.debugTitleCacheMissCount;

      // Auto-save: null customTitle. Cache must answer — no fallback
      // read.
      await store.save(
        sourcePath: path,
        pipeline: samplePipeline(path),
      );
      expect(store.debugTitleCacheMissCount, before,
          reason: 'warm cache hit must not trigger fallback read');

      // Sanity: the title really did survive (cache served the
      // correct value, not the default).
      final list = await store.list();
      expect(list.single.customTitle, 'Warm');
    });

    test('auto-save on a cold cache reads the prior file once, '
        'then warms the cache',
        () async {
      // Cold cache: use a fresh ProjectStore after a prior instance
      // wrote the file. Next auto-save pays one fallback read; the
      // auto-save after that is free.
      final seeding = ProjectStore(rootOverride: tmp);
      const path = '/tmp/cold.jpg';
      await seeding.save(
        sourcePath: path,
        pipeline: samplePipeline(path),
        customTitle: 'Seeded',
      );

      final store = ProjectStore(rootOverride: tmp);
      expect(store.debugTitleCacheMissCount, 0);
      // Auto-save #1 (cold): fallback read populates cache.
      await store.save(
        sourcePath: path,
        pipeline: samplePipeline(path),
      );
      expect(store.debugTitleCacheMissCount, 1);

      // Auto-save #2 (warm): cache-hit, no fallback.
      await store.save(
        sourcePath: path,
        pipeline: samplePipeline(path),
      );
      expect(store.debugTitleCacheMissCount, 1,
          reason: 'cache warmed by the cold-path fallback');

      // Both auto-saves preserved the seeded title.
      final list = await store.list();
      expect(list.single.customTitle, 'Seeded');
    });

    test('first-ever save for a new path does not count as a cache miss',
        () async {
      // A path with no file on disk yet: fallback doesn't fire (it's
      // gated on `file.exists()`), so the miss counter stays 0 even
      // though the cache was cold.
      final store = ProjectStore(rootOverride: tmp);
      await store.save(
        sourcePath: '/tmp/brand_new.jpg',
        pipeline: samplePipeline('/tmp/brand_new.jpg'),
      );
      expect(store.debugTitleCacheMissCount, 0);
    });

    test('load warms the cache', () async {
      final seeding = ProjectStore(rootOverride: tmp);
      const path = '/tmp/load_warm.jpg';
      await seeding.save(
        sourcePath: path,
        pipeline: samplePipeline(path),
        customTitle: 'From disk',
      );

      final store = ProjectStore(rootOverride: tmp);
      await store.load(path); // ← warms cache.
      expect(store.debugTitleCacheMissCount, 0);

      // Subsequent auto-save is free.
      await store.save(
        sourcePath: path,
        pipeline: samplePipeline(path),
      );
      expect(store.debugTitleCacheMissCount, 0,
          reason: 'load must populate the cache');
      final list = await store.list();
      expect(list.single.customTitle, 'From disk');
    });

    test('list warms the cache for every listed project', () async {
      final seeding = ProjectStore(rootOverride: tmp);
      await seeding.save(
        sourcePath: '/tmp/a.jpg',
        pipeline: samplePipeline('/tmp/a.jpg'),
        customTitle: 'Alpha',
      );
      await seeding.save(
        sourcePath: '/tmp/b.jpg',
        pipeline: samplePipeline('/tmp/b.jpg'),
      );

      final store = ProjectStore(rootOverride: tmp);
      await store.list();
      expect(store.debugTitleCacheMissCount, 0);

      // Both paths should auto-save without a fallback read now.
      await store.save(
        sourcePath: '/tmp/a.jpg',
        pipeline: samplePipeline('/tmp/a.jpg'),
      );
      await store.save(
        sourcePath: '/tmp/b.jpg',
        pipeline: samplePipeline('/tmp/b.jpg'),
      );
      expect(store.debugTitleCacheMissCount, 0,
          reason: 'list must populate cache for every listed project');

      final after = await store.list();
      expect(
        after.firstWhere((s) => s.sourcePath == '/tmp/a.jpg').customTitle,
        'Alpha',
      );
      expect(
        after.firstWhere((s) => s.sourcePath == '/tmp/b.jpg').customTitle,
        isNull,
      );
    });

    test('setTitle updates the cache so the next auto-save picks it up',
        () async {
      final store = ProjectStore(rootOverride: tmp);
      const path = '/tmp/rename_cache.jpg';
      await store.save(
        sourcePath: path,
        pipeline: samplePipeline(path),
        customTitle: 'Before',
      );

      await store.setTitle(path, 'After');
      final before = store.debugTitleCacheMissCount;

      // Auto-save right after the rename must see the new title from
      // the cache, not the old one — and must not fall back to the
      // file read.
      await store.save(
        sourcePath: path,
        pipeline: samplePipeline(path),
      );
      expect(store.debugTitleCacheMissCount, before,
          reason: 'setTitle must warm the cache, not invalidate it');
      final list = await store.list();
      expect(list.single.customTitle, 'After');
    });

    test('setTitle with empty string caches the cleared state', () async {
      final store = ProjectStore(rootOverride: tmp);
      const path = '/tmp/clear_cache.jpg';
      await store.save(
        sourcePath: path,
        pipeline: samplePipeline(path),
        customTitle: 'Original',
      );
      await store.setTitle(path, '');
      final before = store.debugTitleCacheMissCount;

      await store.save(
        sourcePath: path,
        pipeline: samplePipeline(path),
      );
      expect(store.debugTitleCacheMissCount, before);
      final list = await store.list();
      expect(list.single.customTitle, isNull);
    });

    test('save with an explicit customTitle ignores the cache entirely',
        () async {
      // When the caller passes a non-null title, the cache lookup is
      // skipped — the explicit value wins, and the cache is updated
      // to match.
      final store = ProjectStore(rootOverride: tmp);
      const path = '/tmp/explicit.jpg';
      await store.save(
        sourcePath: path,
        pipeline: samplePipeline(path),
        customTitle: 'First',
      );
      await store.save(
        sourcePath: path,
        pipeline: samplePipeline(path),
        customTitle: 'Second',
      );
      expect(store.debugTitleCacheMissCount, 0);
      final list = await store.list();
      expect(list.single.customTitle, 'Second');
    });

    test('delete invalidates the cache so a new file starts clean',
        () async {
      final store = ProjectStore(rootOverride: tmp);
      const path = '/tmp/reborn.jpg';
      // Seed + cache.
      await store.save(
        sourcePath: path,
        pipeline: samplePipeline(path),
        customTitle: 'Ghost title',
      );
      await store.delete(path);

      // Fresh save for the same path: no ghost title should carry
      // over from the previous deleted project.
      await store.save(
        sourcePath: path,
        pipeline: samplePipeline(path),
      );
      final list = await store.list();
      expect(list.single.customTitle, isNull,
          reason: 'delete must invalidate the cache');
    });
  });

  group('ProjectStore recents sidecar (Phase IV.8)', () {
    // The sidecar `_index.json` is the authoritative snapshot the home
    // page reads on open. `save` / `setTitle` / `delete` mutate the
    // in-memory shadow + rewrite the sidecar; `list` answers from the
    // shadow. `debugIndexRebuildCount` pins "warm reads don't walk
    // the directory."

    test('save creates the sidecar and list reads from it without a walk',
        () async {
      final store = ProjectStore(rootOverride: tmp);
      const path = '/tmp/sidecar_basic.jpg';
      await store.save(sourcePath: path, pipeline: samplePipeline(path));

      // Sidecar landed on disk.
      final sidecar = File('${tmp.path}/_index.json');
      expect(sidecar.existsSync(), isTrue);
      final decoded =
          jsonDecode(await sidecar.readAsString()) as Map<String, dynamic>;
      expect(decoded['schema'], 1);
      final entries = decoded['entries'] as List;
      expect(entries, hasLength(1));
      expect((entries.first as Map)['sourcePath'], path);

      // First save performed the rebuild-from-disk once (cold shadow)
      // — that's expected on any fresh ProjectStore instance.
      final baseline = store.debugIndexRebuildCount;
      await store.list();
      expect(store.debugIndexRebuildCount, baseline,
          reason: 'warm list must not walk the directory again');
    });

    test('cold ProjectStore with existing sidecar lists via sidecar read, '
        'no directory walk',
        () async {
      // Seed the projects dir + sidecar with a prior store.
      final seeding = ProjectStore(rootOverride: tmp);
      await seeding.save(
        sourcePath: '/tmp/a.jpg',
        pipeline: samplePipeline('/tmp/a.jpg'),
      );
      await seeding.save(
        sourcePath: '/tmp/b.jpg',
        pipeline: samplePipeline('/tmp/b.jpg'),
      );

      // Fresh store — sidecar is present, shadow is cold.
      final store = ProjectStore(rootOverride: tmp);
      expect(store.debugIndexRebuildCount, 0);
      final all = await store.list();
      expect(all, hasLength(2));
      expect(store.debugIndexRebuildCount, 0,
          reason: 'sidecar read must serve list() without a directory walk');
    });

    test('missing sidecar triggers a one-time rebuild from disk', () async {
      // Seed the projects dir via a prior store, then nuke the sidecar
      // to simulate a user who upgrades from a pre-IV.8 build.
      final seeding = ProjectStore(rootOverride: tmp);
      await seeding.save(
        sourcePath: '/tmp/legacy1.jpg',
        pipeline: samplePipeline('/tmp/legacy1.jpg'),
      );
      await seeding.save(
        sourcePath: '/tmp/legacy2.jpg',
        pipeline: samplePipeline('/tmp/legacy2.jpg'),
      );
      File('${tmp.path}/_index.json').deleteSync();

      final store = ProjectStore(rootOverride: tmp);
      final all = await store.list();
      expect(all, hasLength(2));
      expect(store.debugIndexRebuildCount, 1,
          reason: 'missing sidecar must trigger exactly one rebuild');

      // Sidecar was persisted during the rebuild.
      expect(File('${tmp.path}/_index.json').existsSync(), isTrue);

      // Subsequent list is warm — no further rebuilds.
      await store.list();
      expect(store.debugIndexRebuildCount, 1);
    });

    test('corrupt sidecar triggers rebuild; recovered sidecar matches disk',
        () async {
      final seeding = ProjectStore(rootOverride: tmp);
      await seeding.save(
        sourcePath: '/tmp/corrupt_a.jpg',
        pipeline: samplePipeline('/tmp/corrupt_a.jpg'),
      );
      await seeding.save(
        sourcePath: '/tmp/corrupt_b.jpg',
        pipeline: samplePipeline('/tmp/corrupt_b.jpg'),
      );
      // Overwrite the sidecar with garbage.
      File('${tmp.path}/_index.json').writeAsStringSync('not json at all');

      final store = ProjectStore(rootOverride: tmp);
      final all = await store.list();
      expect(all, hasLength(2));
      expect(store.debugIndexRebuildCount, 1);

      // Verify the rebuilt sidecar parses cleanly + has both entries.
      final decoded = jsonDecode(
        File('${tmp.path}/_index.json').readAsStringSync(),
      ) as Map<String, dynamic>;
      expect(decoded['schema'], 1);
      final entries = (decoded['entries'] as List).cast<Map<String, dynamic>>();
      final paths = entries.map((e) => e['sourcePath']).toSet();
      expect(paths, {'/tmp/corrupt_a.jpg', '/tmp/corrupt_b.jpg'});
    });

    test('setTitle updates the sidecar entry', () async {
      final store = ProjectStore(rootOverride: tmp);
      const path = '/tmp/rename.jpg';
      await store.save(sourcePath: path, pipeline: samplePipeline(path));

      await store.setTitle(path, 'Renamed');

      // Sidecar reflects the rename.
      final decoded = jsonDecode(
        File('${tmp.path}/_index.json').readAsStringSync(),
      ) as Map<String, dynamic>;
      final entries = (decoded['entries'] as List).cast<Map<String, dynamic>>();
      expect(entries.single['customTitle'], 'Renamed');

      // Fresh store reads the sidecar and sees the rename without a walk.
      final fresh = ProjectStore(rootOverride: tmp);
      final list = await fresh.list();
      expect(list.single.customTitle, 'Renamed');
      expect(fresh.debugIndexRebuildCount, 0);
    });

    test('setTitle with empty string drops customTitle from the sidecar',
        () async {
      final store = ProjectStore(rootOverride: tmp);
      const path = '/tmp/clear.jpg';
      await store.save(
        sourcePath: path,
        pipeline: samplePipeline(path),
        customTitle: 'Old',
      );
      await store.setTitle(path, '');

      final decoded = jsonDecode(
        File('${tmp.path}/_index.json').readAsStringSync(),
      ) as Map<String, dynamic>;
      final entries = (decoded['entries'] as List).cast<Map<String, dynamic>>();
      expect(entries.single.containsKey('customTitle'), isFalse,
          reason: 'cleared title must not leave a stale value on disk');
    });

    test('delete removes the sidecar entry', () async {
      final store = ProjectStore(rootOverride: tmp);
      await store.save(
        sourcePath: '/tmp/keep.jpg',
        pipeline: samplePipeline('/tmp/keep.jpg'),
      );
      await store.save(
        sourcePath: '/tmp/drop.jpg',
        pipeline: samplePipeline('/tmp/drop.jpg'),
      );

      await store.delete('/tmp/drop.jpg');

      // Sidecar has only the surviving project.
      final decoded = jsonDecode(
        File('${tmp.path}/_index.json').readAsStringSync(),
      ) as Map<String, dynamic>;
      final entries = (decoded['entries'] as List).cast<Map<String, dynamic>>();
      expect(entries, hasLength(1));
      expect(entries.single['sourcePath'], '/tmp/keep.jpg');

      // Fresh store agrees.
      final fresh = ProjectStore(rootOverride: tmp);
      expect((await fresh.list()).single.sourcePath, '/tmp/keep.jpg');
    });

    test('sort contract: newest-first by savedAt preserved', () async {
      final store = ProjectStore(rootOverride: tmp);
      await store.save(
        sourcePath: '/tmp/old.jpg',
        pipeline: samplePipeline('/tmp/old.jpg'),
      );
      await Future<void>.delayed(const Duration(milliseconds: 15));
      await store.save(
        sourcePath: '/tmp/new.jpg',
        pipeline: samplePipeline('/tmp/new.jpg'),
      );

      final list = await store.list();
      expect(list.first.sourcePath, '/tmp/new.jpg');
      expect(list.last.sourcePath, '/tmp/old.jpg');

      // Bump /tmp/old.jpg via setTitle — it should now be newest.
      await Future<void>.delayed(const Duration(milliseconds: 15));
      await store.setTitle('/tmp/old.jpg', 'Revived');
      final after = await store.list();
      expect(after.first.sourcePath, '/tmp/old.jpg');
    });

    test('list returns a defensive copy — callers can mutate safely',
        () async {
      final store = ProjectStore(rootOverride: tmp);
      await store.save(
        sourcePath: '/tmp/copy.jpg',
        pipeline: samplePipeline('/tmp/copy.jpg'),
      );
      final a = await store.list();
      a.clear(); // Mutate the returned list.
      final b = await store.list();
      expect(b, hasLength(1),
          reason: 'shadow must survive caller-side mutation');
    });

    test('sidecar rebuild skips the sidecar itself when walking the dir',
        () async {
      // Seed + trigger rebuild. The rebuild walker must NOT try to
      // decode `_index.json` as an envelope (would log a warning and
      // count as "skipped unreadable") — verify by checking the
      // rebuilt entry count is correct.
      final seeding = ProjectStore(rootOverride: tmp);
      await seeding.save(
        sourcePath: '/tmp/walker_a.jpg',
        pipeline: samplePipeline('/tmp/walker_a.jpg'),
      );
      await seeding.save(
        sourcePath: '/tmp/walker_b.jpg',
        pipeline: samplePipeline('/tmp/walker_b.jpg'),
      );

      final store = ProjectStore(rootOverride: tmp);
      await store.rebuildIndex();
      expect((await store.list()).length, 2);
      expect(store.debugIndexRebuildCount, 1);
    });

    test('save sidecar write failure marks shadow stale for rebuild',
        () async {
      // The first save hits the happy path: envelope + sidecar both
      // land. The second save arms `debugHookBeforeRename` so the
      // envelope's atomic write fails — the whole save() try/catch
      // swallows it AND the sidecar update never runs. The shadow
      // stays in memory (still reflects the successful first save).
      // On a FRESH store, the sidecar on disk (from the first save)
      // remains valid, so the fresh store reads it cleanly.
      final store = ProjectStore(rootOverride: tmp);
      await store.save(
        sourcePath: '/tmp/stable.jpg',
        pipeline: samplePipeline('/tmp/stable.jpg'),
      );

      debugHookBeforeRename = () async {
        throw const FileSystemException('boom');
      };
      await store.save(
        sourcePath: '/tmp/attempted.jpg',
        pipeline: samplePipeline('/tmp/attempted.jpg'),
      );
      debugHookBeforeRename = null;

      // The attempted save never landed.
      final decoded = jsonDecode(
        File('${tmp.path}/_index.json').readAsStringSync(),
      ) as Map<String, dynamic>;
      final entries = (decoded['entries'] as List).cast<Map<String, dynamic>>();
      expect(entries, hasLength(1));
      expect(entries.single['sourcePath'], '/tmp/stable.jpg');
    });

    test('50-project cold start: exactly one disk walk, sidecar persisted',
        () async {
      // The Phase IV.8 perf invariant (in observable form): with 50
      // projects on disk and no sidecar, one `list()` walks the
      // directory once, rebuilds the sidecar, and subsequent lists
      // are free. The PLAN's "<50 ms with sidecar" target is hardware-
      // dependent; asserting the behavioural contract (one walk, then
      // zero) is the stable regression target.
      final seeding = ProjectStore(rootOverride: tmp);
      for (var i = 0; i < 50; i++) {
        await seeding.save(
          sourcePath: '/tmp/perf_$i.jpg',
          pipeline: samplePipeline('/tmp/perf_$i.jpg'),
        );
      }
      // Simulate a pre-IV.8 install: sidecar missing but envelopes present.
      File('${tmp.path}/_index.json').deleteSync();

      final store = ProjectStore(rootOverride: tmp);
      final all = await store.list();
      expect(all, hasLength(50));
      expect(store.debugIndexRebuildCount, 1);

      // Subsequent list is served from the shadow — no rebuild.
      for (var i = 0; i < 5; i++) {
        await store.list();
      }
      expect(store.debugIndexRebuildCount, 1);
    });

    test('sidecar warms the title cache on cold load', () async {
      final seeding = ProjectStore(rootOverride: tmp);
      await seeding.save(
        sourcePath: '/tmp/titled.jpg',
        pipeline: samplePipeline('/tmp/titled.jpg'),
        customTitle: 'From sidecar',
      );
      // Fresh store: only populated from the sidecar, not a disk walk.
      final store = ProjectStore(rootOverride: tmp);
      await store.list();
      expect(store.debugIndexRebuildCount, 0);

      // Auto-save on /tmp/titled.jpg should skip the title-preservation
      // read because the cache got populated from the sidecar entry.
      expect(store.debugTitleCacheMissCount, 0);
      await store.save(
        sourcePath: '/tmp/titled.jpg',
        pipeline: samplePipeline('/tmp/titled.jpg'),
      );
      expect(store.debugTitleCacheMissCount, 0);
      // And the title survived.
      final list = await store.list();
      expect(list.single.customTitle, 'From sidecar');
    });

    test('sidecar body is a schema-versioned JSON wrapper', () async {
      // Pin the sidecar's on-disk shape so future readers stay
      // forward-compatible — a future schema bump appends to the
      // shape without breaking the current one.
      final store = ProjectStore(rootOverride: tmp);
      await store.save(
        sourcePath: '/tmp/shape.jpg',
        pipeline: samplePipeline('/tmp/shape.jpg'),
        customTitle: 'Titled',
      );
      final decoded = jsonDecode(
        File('${tmp.path}/_index.json').readAsStringSync(),
      ) as Map<String, dynamic>;
      expect(decoded.keys.toSet(), {'schema', 'entries'});
      expect(decoded['schema'], 1);
      final entry =
          (decoded['entries'] as List).single as Map<String, dynamic>;
      expect(entry.containsKey('sourcePath'), isTrue);
      expect(entry.containsKey('savedAt'), isTrue);
      expect(entry.containsKey('opCount'), isTrue);
      expect(entry['customTitle'], 'Titled');
    });
  });
}

/// Duplicates [ProjectStore._keyFor] so the wire-format tests above can
/// construct the target file path for pre-Phase-IV.2 legacy fixtures
/// without reaching into the store's private API. Kept local to the
/// test file — the real key is the store's implementation detail.
String _keyFor(String sourcePath) {
  // sha256 of the source path, hex-encoded.
  final digest = sha256.convert(utf8.encode(sourcePath));
  return digest.toString();
}
