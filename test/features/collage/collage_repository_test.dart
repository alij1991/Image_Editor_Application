import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:image_editor/core/io/atomic_file.dart';
import 'package:image_editor/features/collage/data/collage_repository.dart';
import 'package:image_editor/features/collage/domain/collage_state.dart';
import 'package:image_editor/features/collage/domain/collage_template.dart';

/// Behaviour tests for [CollageRepository].
///
/// Coverage focus:
/// - round-trip of every persisted field (template id, images,
///   aspect, borders, corner radius, background colour)
/// - schema migration seam (v0 unwrapped JSON auto-upgrades)
/// - missing-source handling (deleted image paths null out cleanly)
/// - atomicity (crash mid-write preserves prior state)
void main() {
  late Directory tmp;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('collage_repository_test');
    debugHookBeforeRename = null;
  });

  tearDown(() {
    debugHookBeforeRename = null;
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  /// Produce a concrete 3×3 state with real on-disk placeholder
  /// images in each cell. The placeholders are tiny (one JPEG marker
  /// pair each) — enough for `File.existsSync` to succeed without
  /// blowing up test-run disk usage.
  CollageState sampleState() {
    final template = CollageTemplates.byId('grid.3x3');
    final history = <String?>[];
    for (var i = 0; i < template.cells.length; i++) {
      final path = '${tmp.path}/cell_$i.jpg';
      File(path).writeAsBytesSync([0xff, 0xd8, 0xff, 0xd9]);
      history.add(path);
    }
    return CollageState(
      template: template,
      imageHistory: history,
      aspect: CollageAspect.portrait,
      innerBorder: 6,
      outerMargin: 12,
      cornerRadius: 16,
      backgroundColor: const Color(0xFFABCDEF),
    );
  }

  group('CollageRepository round-trip', () {
    test('save → load restores every persisted field', () async {
      final repo = CollageRepository(rootOverride: tmp);
      final original = sampleState();
      await repo.save(original);

      final loaded = await repo.load();
      expect(loaded, isNotNull);
      expect(loaded!.template.id, original.template.id);
      expect(loaded.cells.length, original.cells.length);
      for (var i = 0; i < original.cells.length; i++) {
        expect(loaded.cells[i].imagePath, original.cells[i].imagePath,
            reason: 'cell $i imagePath should survive round-trip');
        // Rect is derived from template on load; confirm it matches.
        expect(loaded.cells[i].rect.left, original.cells[i].rect.left);
      }
      expect(loaded.aspect, CollageAspect.portrait);
      expect(loaded.innerBorder, 6);
      expect(loaded.outerMargin, 12);
      expect(loaded.cornerRadius, 16);
      // Colour round-trips through ARGB32.
      expect(loaded.backgroundColor.toARGB32(), 0xFFABCDEF);
    });

    test('load returns null when nothing has been saved', () async {
      final repo = CollageRepository(rootOverride: tmp);
      expect(await repo.load(), isNull);
    });

    test('save twice overwrites prior state', () async {
      final repo = CollageRepository(rootOverride: tmp);
      final first = sampleState();
      await repo.save(first);

      final second = first.copyWith(
        aspect: CollageAspect.story,
        innerBorder: 20,
      );
      await repo.save(second);

      final loaded = await repo.load();
      expect(loaded, isNotNull);
      expect(loaded!.aspect, CollageAspect.story);
      expect(loaded.innerBorder, 20);
    });

    test('delete removes the persisted file', () async {
      final repo = CollageRepository(rootOverride: tmp);
      await repo.save(sampleState());
      expect(await repo.load(), isNotNull);
      await repo.delete();
      expect(await repo.load(), isNull);
    });

    test('delete on a never-saved repo is a no-op', () async {
      final repo = CollageRepository(rootOverride: tmp);
      // Should not throw.
      await repo.delete();
    });
  });

  group('CollageRepository missing-source handling', () {
    test('load nulls out cells whose imagePath no longer exists',
        () async {
      final repo = CollageRepository(rootOverride: tmp);
      final original = sampleState();
      await repo.save(original);

      // Simulate the user deleting the photo from their gallery
      // between sessions by wiping the placeholder files before
      // reloading.
      for (final c in original.cells) {
        if (c.imagePath != null) {
          File(c.imagePath!).deleteSync();
        }
      }

      final loaded = await repo.load();
      expect(loaded, isNotNull);
      expect(loaded!.cells.length, original.cells.length);
      for (final c in loaded.cells) {
        expect(c.imagePath, isNull,
            reason: 'missing files should null out, not crash');
      }
    });

    test('load with some missing + some present preserves the present',
        () async {
      final repo = CollageRepository(rootOverride: tmp);
      final original = sampleState();
      await repo.save(original);

      // Delete every other cell's placeholder.
      for (var i = 0; i < original.cells.length; i++) {
        if (i.isEven) {
          final path = original.cells[i].imagePath;
          if (path != null) File(path).deleteSync();
        }
      }

      final loaded = await repo.load();
      expect(loaded, isNotNull);
      for (var i = 0; i < loaded!.cells.length; i++) {
        if (i.isEven) {
          expect(loaded.cells[i].imagePath, isNull,
              reason: 'even cells were deleted');
        } else {
          expect(loaded.cells[i].imagePath, isNotNull,
              reason: 'odd cells are still on disk');
        }
      }
    });
  });

  group('CollageRepository migration', () {
    test('loadAll upgrades a pre-schema (v0 unwrapped) file', () async {
      final repo = CollageRepository(rootOverride: tmp);
      // Hand-write the legacy (v0) format: raw CollageState.toJson()
      // at the top level, with no `{schema, state}` wrapper.
      final legacy = sampleState().toJson();
      File('${tmp.path}/latest.json').writeAsStringSync(jsonEncode(legacy));

      final loaded = await repo.load();
      expect(loaded, isNotNull);
      expect(loaded!.template.id, 'grid.3x3');
      expect(loaded.aspect, CollageAspect.portrait);
    });

    test('load tolerates a future-version wrapper (best-effort)', () async {
      final repo = CollageRepository(rootOverride: tmp);
      final legacy = sampleState().toJson();
      File('${tmp.path}/latest.json').writeAsStringSync(
        jsonEncode({'schema': 99, 'state': legacy}),
      );

      final loaded = await repo.load();
      expect(loaded, isNotNull);
      expect(loaded!.aspect, CollageAspect.portrait);
    });

    test('save writes a wrapped v1 envelope on disk', () async {
      final repo = CollageRepository(rootOverride: tmp);
      await repo.save(sampleState());

      final onDisk = jsonDecode(
        File('${tmp.path}/latest.json').readAsStringSync(),
      ) as Map<String, dynamic>;
      expect(onDisk['schema'], 1);
      expect(onDisk['state'], isA<Map<String, dynamic>>());
      expect((onDisk['state'] as Map)['templateId'], 'grid.3x3');
    });

    test('unknown template id falls back to the first template',
        () async {
      final repo = CollageRepository(rootOverride: tmp);
      // Write a v1 envelope with a template id that doesn't exist.
      File('${tmp.path}/latest.json').writeAsStringSync(
        jsonEncode({
          'schema': 1,
          'state': {
            'templateId': 'never.existed',
            'imagePaths': [],
            'aspect': 'square',
            'innerBorder': 4.0,
            'outerMargin': 8.0,
            'cornerRadius': 0.0,
            'backgroundColor': 0xFFFFFFFF,
          },
        }),
      );
      final loaded = await repo.load();
      expect(loaded, isNotNull);
      // byId falls back to CollageTemplates.all.first.
      expect(loaded!.template.id, CollageTemplates.all.first.id);
    });
  });

  group('CollageRepository atomic save', () {
    test('crash between flush and rename preserves prior content',
        () async {
      final repo = CollageRepository(rootOverride: tmp);
      final first = sampleState();
      await repo.save(first);
      expect((await repo.load())!.innerBorder, 6);

      // Crash on the second save — `CollageRepository.save` swallows
      // exceptions (auto-save is fire-and-forget) so we don't
      // expect a throw at the call site.
      debugHookBeforeRename = () async {
        throw const FileSystemException('simulated crash');
      };
      await repo.save(first.copyWith(innerBorder: 99));

      final recovered = await repo.load();
      expect(recovered, isNotNull);
      expect(recovered!.innerBorder, 6,
          reason: 'the crashed save must not land the new innerBorder');
    });

    test('successful save leaves no .tmp sibling', () async {
      final repo = CollageRepository(rootOverride: tmp);
      await repo.save(sampleState());
      final leftovers = tmp
          .listSync(recursive: false)
          .whereType<File>()
          .where((f) => f.path.endsWith('.tmp'))
          .toList();
      expect(leftovers, isEmpty);
    });
  });
}
